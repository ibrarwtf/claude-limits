using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

using static ClaudeLimits.Logic;

namespace ClaudeLimits
{
    /// The AppDelegate port: owns state, timers, polling, animations, the tray
    /// icon and the pill. Method names track AppDelegate.swift so a change to
    /// one is easy to find in the other.
    sealed class TrayApp
    {
        Forms.NotifyIcon tray;
        PillWindow pill;
        FlyoutWindow flyout;
        DateTime flyoutClosedAt;
        SettingsWindow settingsWindow;

        DispatcherTimer pollTimer, animationTimer, tickTimer, rateLimitCycleTimer, updateCheckTimer;
        int animationFrame;
        DateTime? animationStartedAt;
        /// Bumped per StartAnimation(); a deferred stop from an older cycle no-ops.
        int animationGeneration;
        public bool IsRefreshing { get; private set; }
        CancellationTokenSource currentTask;
        Guid? currentRequestToken;
        public UsageResponse LastResponse { get; private set; }
        public DateTime? LastUpdated { get; private set; }
        public AppError LastError { get; private set; }

        int rateLimitAnimFrame;   // cold-start error animation (error_tick in logic/core.pl)
        int marqueeWindowChars = 22;

        public GitHubRelease LatestVersionAvailable { get; private set; }

        public DateTime? LastManualClickAt { get; set; }   // click-storm guard (click_effect)
        DateTime? nextPollAt;                              // for "next in Xs"

        MenuBarTitle currentTitle = new MenuBarTitle { Plain = "—" };
        string trayIconKey;
        static readonly Random rng = new Random();

        static Dispatcher UI => Application.Current.Dispatcher;
        static DateTime Now => Clock.Now;

        public void Start()
        {
            SelfUpdate.CleanupOldExe();
            Platform.RegisterUrlScheme();
            Platform.RefreshRunAtStartupPath();
            Theme.Init();
            Theme.Changed += () => { trayIconKey = null; ApplyTitle(currentTitle); };

            tray = new Forms.NotifyIcon { Text = "claude-limits", Visible = true };
            tray.Icon = TrayIcon.AppIcon(Forms.SystemInformation.SmallIconSize.Width);
            // Windows convention: either button opens the flyout from the tray;
            // refresh is the pill's left-click and a flyout row.
            tray.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left || e.Button == Forms.MouseButtons.Right) ToggleFlyoutAtCursor(); };

            pill = new PillWindow(this);
            if (Settings.Shared.ShowPill) pill.ShowPill();

            ComputeWidthBudget();

            // Show the last response straight away, before the first poll lands.
            var json = Settings.Shared.LastResponseJSON;
            if (!string.IsNullOrEmpty(json))
            {
                try
                {
                    LastResponse = Json.Parse<UsageResponse>(json);
                    LastUpdated = Settings.Shared.LastSuccessfulPoll;
                    UpdateTitle();
                }
                catch { }
            }

            // Still inside a 429 back-off from the previous process: mirror it.
            LastError = BackoffError(Settings.Shared.NextAllowedPoll, Now);
            if (LastError != null && LastResponse == null) StartRateLimitCycle();

            if (ShouldPoll(Settings.Shared.NextAllowedPoll, Settings.Shared.LastSuccessfulPoll, Now)) TriggerRefresh(animated: true);
            else UpdateTitle();
            SchedulePoll();

            // Tick the title every 30s to update the reset countdown without a fetch.
            tickTimer = Every(30, UpdateTitle);

            // Update check shortly after launch, then daily (GitHub allows 60/h anonymous).
            After(5, () => { var _ = CheckForLatestRelease(); });
            updateCheckTimer = Every(24 * 3600, () => { var _ = CheckForLatestRelease(); });

            if (!Settings.Shared.DidFirstLaunch)
            {
                Settings.Shared.DidFirstLaunch = true;
                // Zip installs get autostart without flipping a setting.
                Settings.Shared.LaunchAtStartup = true;
                UI.BeginInvoke(new Action(OpenSettings));
            }
        }

        /// `--fixture`: canned data, no polling, update checks, notifications or
        /// registry side effects. With `--snapshot-all`, render every view and
        /// quit; without it, show the tray icon + pill for eyeballing UI changes.
        public void StartFixture()
        {
            ComputeWidthBudget();
            LastResponse = FixtureMode.Fixture.Response;
            LastUpdated = Now;
            nextPollAt = Now.AddSeconds(PollInterval);
            if (FixtureMode.SnapshotDest != null)
            {
                currentTitle = DataTitle(respectToggles: true);
                Snapshot.RenderAll(this, FixtureMode.SnapshotDest);
                Application.Current.Shutdown();
                return;
            }
            tray = new Forms.NotifyIcon { Text = "claude-limits (fixture)", Visible = true };
            tray.MouseClick += (_, e) => ToggleFlyoutAtCursor();
            pill = new PillWindow(this);
            pill.ShowPill();
            UpdateTitle();
        }

        static DispatcherTimer Every(double seconds, Action a)
        {
            var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
            t.Tick += (_, __) => a();
            t.Start();
            return t;
        }

        static void After(double seconds, Action a)
        {
            var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Math.Max(0.001, seconds)) };
            t.Tick += (_, __) => { t.Stop(); a(); };
            t.Start();
        }

        /// Size the marquee window from the worst-case "all three on" pill, so the
        /// scrolling error text never makes the pill wider than real data does.
        void ComputeWidthBudget()
        {
            double max = PillView.Measure("100%", Theme.UIFont, 12) + 6 + 10 * 4.5 + 6 + PillView.Measure("9:59", Theme.UIFont, 12);
            double charWidth = PillView.Measure(new string('M', 50), Theme.MonoFont, 11.5) / 50.0;
            marqueeWindowChars = Math.Max(8, (int)Math.Floor(max / charWidth));
        }

        /// Remembers a newer release in LatestVersionAvailable (Settings shows it).
        public async Task<(GitHubRelease, Exception)> CheckForLatestRelease()
        {
            try
            {
                var r = await Updates.FetchLatestReleaseAsync();
                LatestVersionAvailable = r != null && IsNewerVersion(r.TagName, Platform.Version) ? r : null;
                return (LatestVersionAvailable, null);
            }
            catch (Exception e) { return (null, e); }
        }

        /// Posted just before quitting for a self-update, while the tray icon is gone.
        public void NotifyUpdating(string version) =>
            tray.ShowBalloonTip(4000, "Updating claude-limits",
                UpdatingNotice(version, "tray icon"), Forms.ToolTipIcon.Info);

        void SchedulePoll()
        {
            pollTimer?.Stop();
            nextPollAt = Now.AddSeconds(PollInterval);
            pollTimer = Every(PollInterval, () =>
            {
                nextPollAt = Now.AddSeconds(PollInterval);
                if (ShouldPoll(Settings.Shared.NextAllowedPoll, Settings.Shared.LastSuccessfulPoll, Now)) TriggerRefresh(animated: false);
                else UpdateTitle();
            });
        }

        /// Pill left-click — the Mac status item's left-click.
        public void PrimaryClick() => ManualRefresh(fromClick: true);

        /// See click_effect in logic/core.pl. "Refresh now" shares the click-storm
        /// cooldown but stays silent during a 429 back-off.
        void ManualRefresh(bool fromClick)
        {
            switch (ClickEffect(Settings.Shared.NextAllowedPoll, LastManualClickAt, Now))
            {
                case Click.Blocked:
                    if (!fromClick) return;
                    LastError = BackoffError(Settings.Shared.NextAllowedPoll, Now);
                    PlayClickAnimation();
                    break;
                case Click.Cooling: PlayClickAnimation(); break;
                default:
                    LastManualClickAt = Now;
                    TriggerRefresh(animated: true, force: true);
                    break;
            }
        }

        void PlayClickAnimation() { StartAnimation(); StopAnimationAfter(1.5); }

        public void ToggleFlyout(Native.RECT anchor, bool fromPill)
        {
            if (flyout != null) { flyout.Close(); return; }
            // A click on the tray icon while the flyout is open first deactivates
            // (closes) it, then delivers the click — don't reopen on that click.
            if ((DateTime.Now - flyoutClosedAt).TotalMilliseconds < 300) return;
            flyout = new FlyoutWindow(this);
            flyout.Closed += (_, __) => { flyout = null; flyoutClosedAt = DateTime.Now; };
            flyout.ShowAt(anchor, fromPill);
        }

        void ToggleFlyoutAtCursor()
        {
            Native.GetCursorPos(out var p);
            ToggleFlyout(new Native.RECT { Left = p.X, Top = p.Y, Right = p.X, Bottom = p.Y }, fromPill: false);
        }

        // ── Title rendering ──────────────────────────────────────────────────

        /// Current data as a title. respectToggles=false is the flyout header,
        /// which always shows all three parts.
        public MenuBarTitle DataTitle(bool respectToggles)
        {
            if (LastResponse?.FiveHour is UsageBucket f)
            {
                var s = Settings.Shared;
                bool all = !respectToggles;
                int pct = Percent(f.Utilization);
                return MenuBarTitle.From(TitleParts(all || s.ShowPercentage, all || s.ShowWave, all || s.ShowResetTime, $"{pct}%",
                    Sparkline(UsageHistory.Shared.Samples, SparkWidth), Countdown(f.ResetsAt, Now)), all || s.ShowPercentage ? pct : (int?)null, f.Utilization);
            }
            if (LastError != null) return new MenuBarTitle { Plain = ErrorSymbol(LastError), IsError = true };
            return new MenuBarTitle { Plain = "—" };
        }

        public void UpdateTitle()
        {
            if (IsRefreshing || animationTimer != null || rateLimitCycleTimer != null) return;
            ApplyTitle(DataTitle(respectToggles: true));
        }

        void ApplyTitle(MenuBarTitle t)
        {
            currentTitle = t;
            pill?.Render(t);
            UpdateTrayIcon(t);
        }

        void UpdateTrayIcon(MenuBarTitle t)
        {
            bool err = t.IsError || LastResponse == null && LastError != null;
            string text = TrayText(t.TrayNumber, err, t.Plain);
            var level = (IconLevel)TrayLevel(t.TrayNumber, t.Utilization, err);

            bool dark = Theme.SystemDark;
            int size = Forms.SystemInformation.SmallIconSize.Width;
            var key = $"{text}|{level}|{dark}|{size}";
            if (key != trayIconKey)
            {
                trayIconKey = key;
                var old = tray.Icon;
                tray.Icon = text == null ? TrayIcon.AppIcon(size) : TrayIcon.Render(text, level, dark, size);
                old?.Dispose();
            }
            tray.Text = Tooltip(LastResponse?.FiveHour?.Utilization, LastResponse?.FiveHour?.ResetsAt, LastError, Now);
        }

        // Snapshot capture lives in Snapshot.cs.
        public MenuBarTitle CurrentTitle => currentTitle;

        // ── Refresh + animation ──────────────────────────────────────────────

        /// Record a 429 and return the "do not poll until" deadline. Shared by the
        /// poller and Settings "Test fetch" so no entry point can skip the back-off.
        public DateTime RecordRateLimit(double? retry)
        {
            var until = Now.AddSeconds(BackoffSecs(++Settings.Shared.ConsecutiveRateLimits, retry));
            Settings.Shared.NextAllowedPoll = until;
            return until;
        }

        public async void TriggerRefresh(bool animated, bool force = false)
        {
            if (IsRefreshing && !force) return;
            if (force) currentTask?.Cancel();
            IsRefreshing = true;
            if (animated) StartAnimation();
            // A manual refresh restarts the poll timer so we don't double-poll.
            if (force) SchedulePoll();
            var myToken = Guid.NewGuid();
            currentRequestToken = myToken;
            var cts = new CancellationTokenSource();
            currentTask = cts;

            var result = await Api.FetchUsageAsync(cts.Token);
            if (result == null || currentRequestToken != myToken) return;
            IsRefreshing = false;
            ScheduleAnimationStop();
            if (result.IsSuccess)
            {
                var r = result.Value;
                LastResponse = r;
                LastUpdated = Now;
                LastError = null;
                Settings.Shared.LastSuccessfulPoll = Now;
                Settings.Shared.NextAllowedPoll = null;
                Settings.Shared.ConsecutiveRateLimits = 0;
                Settings.Shared.LastResponseJSON = Json.Write(r);
                StopRateLimitCycle();
                if (r.FiveHour != null)
                {
                    UsageHistory.Shared.Append(r.FiveHour.Utilization, r.FiveHour.ResetsAt);
                    CheckAndNotifyThresholds(r.FiveHour);
                }
            }
            else
            {
                var e = result.Error;
                LastError = e;
                UsageHistory.Shared.AppendError();
                if (e.Kind == AppErrorKind.RateLimited)
                {
                    var until = RecordRateLimit(e.RetryAfter);
                    int count = Settings.Shared.ConsecutiveRateLimits;
                    int secs = (int)Math.Round((until - Now).TotalSeconds);
                    Log.Write($"claude-limits rate limited (#{count}) — next attempt at {until.ToLocalTime():HH:mm:ss} (waiting {secs}s)");
                }
                else
                {
                    Log.Write($"claude-limits fetch error: {FriendlyMessage(e)}");
                }
                if (LastResponse == null) StartRateLimitCycle();
                else StopRateLimitCycle();
            }
            UpdateTitle();
        }

        /// Bouncing-peak palindrome animation, 12 fps, while a refresh is in flight.
        void StartAnimation()
        {
            animationTimer?.Stop();
            animationFrame = 0;
            animationStartedAt = Now;
            animationGeneration += 1;
            animationTimer = Every(1.0 / 12.0, () =>
            {
                // Slot-machine reels: % and reset spin while the bars dance;
                // hidden parts stay hidden.
                var s = Settings.Shared;
                int pct = rng.Next(0, 100);
                ApplyTitle(MenuBarTitle.From(TitleParts(s.ShowPercentage, s.ShowWave, s.ShowResetTime, $"{pct}%", WaveFrame(animationFrame),
                    $"{rng.Next(0, 10)}:{rng.Next(0, 60):00}"), s.ShowPercentage ? pct : (int?)null, 0));
                animationFrame += 1;
            });
        }

        void ScheduleAnimationStop() => StopAnimationAfter(AnimationLeft(animationStartedAt, Now));

        /// Unless a newer cycle has started by then.
        void StopAnimationAfter(double seconds)
        {
            if (seconds <= 0) { StopAnimation(); return; }
            int gen = animationGeneration;
            After(seconds, () => { if (animationGeneration == gen) StopAnimation(); });
        }

        void StopAnimation()
        {
            animationTimer?.Stop();
            animationTimer = null;
            animationStartedAt = null;
            UpdateTitle();
        }

        // ── Error animation cycle (frames from error_tick) ───────────────────

        void StartRateLimitCycle()
        {
            rateLimitCycleTimer?.Stop();
            rateLimitAnimFrame = 0;
            rateLimitCycleTimer = Every(1.0 / 12.0, TickRateLimitCycle);
        }

        void StopRateLimitCycle() { rateLimitCycleTimer?.Stop(); rateLimitCycleTimer = null; }

        void TickRateLimitCycle()
        {
            var text = ErrorTick(LastError, Settings.Shared.NextAllowedPoll, Now, rateLimitAnimFrame++, marqueeWindowChars);
            if (text == null) { StopRateLimitCycle(); UpdateTitle(); return; }
            ApplyTitle(new MenuBarTitle { Plain = text, Mono = true, IsError = true });
        }

        // ── Flyout text ──────────────────────────────────────────────────────

        public string FormatResetLine(UsageBucket f) => ResetLine(f.Utilization, f.ResetsAt, UsageHistory.Shared.Samples, Now);

        /// 80% / 95% alerts, once per window (alerts in logic/core.pl).
        void CheckAndNotifyThresholds(UsageBucket f)
        {
            var s = Settings.Shared;
            var (key, fired, due) = Alerts(f.Utilization, f.ResetsAt, s.LastNotifiedResetsAt, s.NotifiedThresholds.ToList());
            if (key != s.LastNotifiedResetsAt) s.LastNotifiedResetsAt = key;
            s.NotifiedThresholds = new System.Collections.Generic.HashSet<int>(fired);
            // Balloon tips surface as Windows toasts on 10/11.
            foreach (var t in due) tray.ShowBalloonTip(8000, AlertTitle(t), AlertBody(t), Forms.ToolTipIcon.Warning);
        }

        public string FormatTopStatusLine() => StatusLine(LastError, LastUpdated, Settings.Shared.NextAllowedPoll, nextPollAt, Now);

        // ── Actions ──────────────────────────────────────────────────────────

        public void RefreshAction() => ManualRefresh(fromClick: false);

        public void OpenUsageWeb() => Platform.OpenUrl("https://claude.ai/settings/usage");

        public void OpenSettings()
        {
            if (settingsWindow == null)
            {
                settingsWindow = new SettingsWindow(this, onSave: () =>
                {
                    ApplyPillVisibility();
                    SchedulePoll();
                    TriggerRefresh(animated: true, force: true);
                });
                settingsWindow.Closed += (_, __) => settingsWindow = null;
                settingsWindow.Show();
            }
            if (settingsWindow.WindowState == WindowState.Minimized) settingsWindow.WindowState = WindowState.Normal;
            settingsWindow.Activate();
            // A tray app isn't the foreground process, so Activate alone may just
            // flash the taskbar button; a brief Topmost toggle reliably raises it.
            settingsWindow.Topmost = true;
            settingsWindow.Topmost = false;
            settingsWindow.Focus();
        }

        void ApplyPillVisibility() { if (Settings.Shared.ShowPill) pill.ShowPill(); else pill.HidePill(); }

        public void Quit()
        {
            tray.Visible = false;
            tray.Dispose();
            Application.Current.Shutdown();
        }

        /// claude-limits://… from a second instance or the shell.
        public void HandleUrl(string raw)
        {
            if (!Uri.TryCreate(raw, UriKind.Absolute, out var url)) return;
            switch (url.Host.ToLowerInvariant())
            {
                case "snapshot": Snapshot.Handle(this, url); break;
                case "settings": OpenSettings(); break;
                case "flyout": if (pill.IsVisible) ToggleFlyout(pill.ScreenRect(), fromPill: true); else ToggleFlyoutAtCursor(); break;
                case "quit": Quit(); break;
            }
        }
    }
}
