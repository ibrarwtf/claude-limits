using System;
using System.Diagnostics;
using System.Globalization;
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
        /// Bumped each time StartAnimation() begins a cycle. Deferred stops capture
        /// this value when scheduled and no-op if a newer cycle has since started,
        /// so a stale timer can't tear down a fresh animation.
        int animationGeneration;
        public bool IsRefreshing { get; private set; }
        CancellationTokenSource currentTask;
        Guid? currentRequestToken;
        public UsageResponse LastResponse { get; private set; }
        public DateTime? LastUpdated { get; private set; }
        public AppError LastError { get; private set; }

        // Error animation cycle (cold-start only — runs only when there's no
        // prior successful data). Monotonic 12 fps counter; cyclePos picks phase.
        int rateLimitAnimFrame;
        int marqueeWindowChars = 22;

        public GitHubRelease LatestVersionAvailable { get; private set; }

        /// Click-storm cooldown: rapid manual clicks each previously cancelled the
        /// in-flight task and started a new fetch — so 10 clicks in 1s could hit
        /// Anthropic 10 times before any cancellation took effect. With this gate,
        /// manual fetches are throttled to one per `ManualClickCooldown` seconds;
        /// excess clicks just play the acknowledgement wave.
        public DateTime? LastManualClickAt { get; set; }
        /// Used for "next in Xs" rendering.
        DateTime? nextPollAt;

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
            tray.MouseClick += (_, e) =>
            {
                // Windows convention: either button opens the flyout from the
                // tray; refresh is the pill's left-click and a flyout row.
                if (e.Button == Forms.MouseButtons.Left || e.Button == Forms.MouseButtons.Right)
                {
                    Native.GetCursorPos(out var p);
                    ToggleFlyout(new Native.RECT { Left = p.X, Top = p.Y, Right = p.X, Bottom = p.Y }, fromPill: false);
                }
            };

            pill = new PillWindow(this);
            if (Settings.Shared.ShowPill) pill.ShowPill();

            ComputeWidthBudget();

            // Restore last successful response from disk so we render real data
            // immediately, even before the first poll completes.
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

            // Still inside a rate-limit window from the previous process? Mirror
            // the error state. Marquee only runs when there's no prior data.
            var until = Settings.Shared.NextAllowedPoll;
            if (until.HasValue && until.Value > Now)
            {
                LastError = AppError.RateLimited((until.Value - Now).TotalSeconds);
                if (LastResponse == null) StartRateLimitCycle();
            }

            if (ShouldPoll(Settings.Shared.NextAllowedPoll, Settings.Shared.LastSuccessfulPoll, Now)) TriggerRefresh(animated: true);
            else UpdateTitle();
            SchedulePoll();

            // Tick the title every 30s to update the reset countdown without a fetch.
            tickTimer = Every(30, UpdateTitle);

            // Update check: once at launch (small delay so the first poll lands
            // first), then daily. GitHub anonymous limit is 60/h, so daily is fine.
            After(5, () => { var _ = CheckForLatestRelease(); });
            updateCheckTimer = Every(24 * 3600, () => { var _ = CheckForLatestRelease(); });

            if (!Settings.Shared.DidFirstLaunch)
            {
                Settings.Shared.DidFirstLaunch = true;
                // Auto-enable autostart on first launch so zip-installed users
                // get a working Run entry without flipping a setting.
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
            tray.MouseClick += (_, e) =>
            {
                Native.GetCursorPos(out var p);
                ToggleFlyout(new Native.RECT { Left = p.X, Top = p.Y, Right = p.X, Bottom = p.Y }, fromPill: false);
            };
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

        /// Hit the GitHub Releases API and remember whether a newer version is
        /// available. UI consumers read `LatestVersionAvailable` to render hints.
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

        /// Breadcrumb posted just before we quit for a self-update — the tray icon
        /// briefly vanishes while the new exe starts.
        public void NotifyUpdating(string version) =>
            tray.ShowBalloonTip(4000, "Updating claude-limits",
                $"Installing {version} — the tray icon will return in a few seconds.", Forms.ToolTipIcon.Info);

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
        public void PrimaryClick()
        {
            // Rate-limited → click-acknowledgement wave only, no fetch.
            var until = Settings.Shared.NextAllowedPoll;
            if (until.HasValue && until.Value > Now)
            {
                LastError = AppError.RateLimited((until.Value - Now).TotalSeconds);
                PlayClickAnimation();
                return;
            }
            // Click-storm cooldown → wave only, no fetch.
            if (CoolingDown(LastManualClickAt, Now))
            {
                PlayClickAnimation();
                return;
            }
            LastManualClickAt = Now;
            TriggerRefresh(animated: true, force: true);
        }

        void PlayClickAnimation()
        {
            StartAnimation();
            int gen = animationGeneration;
            After(1.5, () => { if (animationGeneration == gen) StopAnimation(); });
        }

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

        // ── Title rendering ──────────────────────────────────────────────────

        /// Current data as a title. respectToggles=false is the flyout header,
        /// which always shows all three parts.
        public MenuBarTitle DataTitle(bool respectToggles)
        {
            if (LastResponse?.FiveHour is UsageBucket f)
            {
                var s = Settings.Shared;
                int pct = Percent(f.Utilization);
                var t = new MenuBarTitle
                {
                    Pct = !respectToggles || s.ShowPercentage ? $"{pct}%" : null,
                    Wave = !respectToggles || s.ShowWave ? Sparkline(UsageHistory.Shared.Samples, SparkWidth) : null,
                    Reset = !respectToggles || s.ShowResetTime ? Countdown(f.ResetsAt, Now) : null,
                    TrayNumber = s.ShowPercentage || !respectToggles ? pct : (int?)null,
                    Utilization = f.Utilization,
                };
                // All sub-toggles off — show a single dot so the click target stays alive.
                if (t.IsEmpty) t.Plain = "·";
                return t;
            }
            if (LastError != null) return new MenuBarTitle { Plain = ErrorSymbol(LastError), IsError = true };
            return new MenuBarTitle { Plain = "—" };
        }

        public void UpdateTitle()
        {
            if (IsRefreshing || animationTimer != null) return;
            if (rateLimitCycleTimer != null) return;
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
            string text; IconLevel level;
            if (t.TrayNumber is int n) { text = n.ToString(CultureInfo.InvariantCulture); level = (IconLevel)IconLevel(t.Utilization); }
            else if (t.IsError || LastResponse == null && LastError != null) { text = "!"; level = IconLevel.Error; }
            else if (t.Plain == "—") { text = "–"; level = IconLevel.Normal; }
            else { text = null; level = IconLevel.Normal; }

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
            // Manual refreshes push the periodic timer's next-fire forward by a
            // full interval so we don't double-poll right after a manual click.
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
                var frame = WaveFrame(animationFrame);
                // Slot-machine reels: % and reset spin while bars dance. Each
                // piece is gated by its visibility toggle so a hidden part stays
                // hidden during the click-acknowledgement animation.
                var s = Settings.Shared;
                int pct = rng.Next(0, 100);
                var t = new MenuBarTitle
                {
                    Pct = s.ShowPercentage ? $"{pct}%" : null,
                    Wave = s.ShowWave ? frame : null,
                    Reset = s.ShowResetTime ? $"{rng.Next(0, 10)}:{rng.Next(0, 60):00}" : null,
                    TrayNumber = s.ShowPercentage ? pct : (int?)null,
                    Utilization = 0,
                };
                if (t.IsEmpty) t.Plain = "·";
                ApplyTitle(t);
                animationFrame += 1;
            });
        }

        void ScheduleAnimationStop()
        {
            double elapsed = animationStartedAt.HasValue ? (Now - animationStartedAt.Value).TotalSeconds : MinAnimation;
            double remaining = Math.Max(0, MinAnimation - elapsed);
            if (remaining <= 0) StopAnimation();
            else
            {
                int gen = animationGeneration;
                After(remaining, () => { if (animationGeneration == gen) StopAnimation(); });
            }
        }

        void StopAnimation()
        {
            animationTimer?.Stop();
            animationTimer = null;
            animationStartedAt = null;
            UpdateTitle();
        }

        // ── Error animation cycle ───────────────────────────────────────────
        // Phase A bouncing wave (~1.5s), Phase B marquee scroll of friendly
        // message. Both render mono within the width budget.

        void StartRateLimitCycle()
        {
            rateLimitCycleTimer?.Stop();
            rateLimitAnimFrame = 0;
            rateLimitCycleTimer = Every(1.0 / 12.0, TickRateLimitCycle);
        }

        void StopRateLimitCycle()
        {
            rateLimitCycleTimer?.Stop();
            rateLimitCycleTimer = null;
        }

        void TickRateLimitCycle()
        {
            if (LastError == null) { StopRateLimitCycle(); UpdateTitle(); return; }
            var until = Settings.Shared.NextAllowedPoll;
            if (LastError.Kind == AppErrorKind.RateLimited && until.HasValue && until.Value <= Now)
            { StopRateLimitCycle(); UpdateTitle(); return; }
            var text = ErrorFrame(rateLimitAnimFrame++, MarqueeText(LastError, until, Now), marqueeWindowChars);
            if (text == null) { StopRateLimitCycle(); UpdateTitle(); return; }
            ApplyTitle(new MenuBarTitle { Plain = text, Mono = true, IsError = true });
        }

        // ── Flyout text ──────────────────────────────────────────────────────

        public string FormatResetLine(UsageBucket f) => ResetLine(f.Utilization, f.ResetsAt, UsageHistory.Shared.Samples, Now);

        /// Fire one-shot notifications when 5h utilization first crosses 80% / 95%.
        /// State is keyed to the live `resets_at` so each new window starts fresh,
        /// and a relaunch mid-window won't re-notify.
        void CheckAndNotifyThresholds(UsageBucket f)
        {
            var s = Settings.Shared;
            // Only roll over the dedup set on a real resets_at change. The API can
            // intermittently drop resets_at to nil mid-window; treating that as a
            // rollover would clear the set and re-fire the 80/95% alerts.
            if (f.ResetsAt != null && f.ResetsAt != s.LastNotifiedResetsAt)
            {
                s.LastNotifiedResetsAt = f.ResetsAt;
                s.NotifiedThresholds = new System.Collections.Generic.HashSet<int>();
            }
            var fired = s.NotifiedThresholds;
            foreach (var t in Crossed(f.Utilization, fired.ToList()))
            {
                // Balloon tips surface as Windows toasts on 10/11.
                tray.ShowBalloonTip(8000, AlertTitle(t), AlertBody(t), Forms.ToolTipIcon.Warning);
                fired.Add(t);
            }
            s.NotifiedThresholds = fired;
        }

        public string FormatTopStatusLine() => StatusLine(LastError, LastUpdated, Settings.Shared.NextAllowedPoll, nextPollAt, Now);

        // ── Actions ──────────────────────────────────────────────────────────

        public void RefreshAction()
        {
            var until = Settings.Shared.NextAllowedPoll;
            if (until.HasValue && until.Value > Now) return;
            // Share the pill click-storm cooldown so repeated "Refresh now"
            // taps can't bypass the throttle PrimaryClick enforces.
            if (CoolingDown(LastManualClickAt, Now))
            {
                PlayClickAnimation();
                return;
            }
            LastManualClickAt = Now;
            TriggerRefresh(animated: true, force: true);
        }

        public void OpenUsageWeb()
        {
            try { Process.Start(new ProcessStartInfo("https://claude.ai/settings/usage") { UseShellExecute = true }); } catch { }
        }

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

        void ApplyPillVisibility()
        {
            if (Settings.Shared.ShowPill) pill.ShowPill();
            else pill.HidePill();
        }

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
                case "flyout":
                    if (pill.IsVisible) ToggleFlyout(pill.ScreenRect(), fromPill: true);
                    else
                    {
                        Native.GetCursorPos(out var p);
                        ToggleFlyout(new Native.RECT { Left = p.X, Top = p.Y, Right = p.X, Bottom = p.Y }, fromPill: false);
                    }
                    break;
                case "quit": Quit(); break;
            }
        }
    }
}
