using System;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

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
        /// One full bounce of the wave palindrome is 18 frames @ 12 fps = 1.5 s.
        /// Animation must run at least that long for the bounce to be visible.
        const double minAnimationDuration = 1.5;
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
        public const double ManualClickCooldown = 5.0;
        /// Used for "next in Xs" rendering.
        DateTime? nextPollAt;

        MenuBarTitle currentTitle = new MenuBarTitle { Plain = "—" };
        string trayIconKey;
        static readonly Random rng = new Random();

        static Dispatcher UI => Application.Current.Dispatcher;
        static DateTime Now => DateTime.UtcNow;

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

            if (ShouldPollNow()) TriggerRefresh(animated: true);
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
                LatestVersionAvailable = r != null && Updates.IsNewerVersion(r.TagName, Platform.Version) ? r : null;
                return (LatestVersionAvailable, null);
            }
            catch (Exception e) { return (null, e); }
        }

        /// Breadcrumb posted just before we quit for a self-update — the tray icon
        /// briefly vanishes while the new exe starts.
        public void NotifyUpdating(string version) =>
            tray.ShowBalloonTip(4000, "Updating claude-limits",
                $"Installing {version} — the tray icon will return in a few seconds.", Forms.ToolTipIcon.Info);

        /// Returns true if we may issue a fetch right now.
        /// Rate-limit suspension and a per-launch debounce protect Anthropic's API.
        bool ShouldPollNow()
        {
            var until = Settings.Shared.NextAllowedPoll;
            if (until.HasValue && until.Value > Now) return false;
            var last = Settings.Shared.LastSuccessfulPoll;
            // Don't burst on relaunch — wait at least half a poll interval since
            // the most recent successful fetch (may be from a previous process).
            if (last.HasValue && (Now - last.Value).TotalSeconds < UsageHistory.PollIntervalSeconds / 2) return false;
            return true;
        }

        void SchedulePoll()
        {
            pollTimer?.Stop();
            nextPollAt = Now.AddSeconds(UsageHistory.PollIntervalSeconds);
            pollTimer = Every(UsageHistory.PollIntervalSeconds, () =>
            {
                nextPollAt = Now.AddSeconds(UsageHistory.PollIntervalSeconds);
                if (ShouldPollNow()) TriggerRefresh(animated: false);
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
            if (LastManualClickAt.HasValue && (Now - LastManualClickAt.Value).TotalSeconds < ManualClickCooldown)
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
                int pct = (int)Math.Round(f.Utilization, MidpointRounding.AwayFromZero);
                var t = new MenuBarTitle
                {
                    Pct = !respectToggles || s.ShowPercentage ? $"{pct}%" : null,
                    Wave = !respectToggles || s.ShowWave ? UsageHistory.Shared.Sparkline(10) : null,
                    Reset = !respectToggles || s.ShowResetTime ? Format.TimeRemaining(f.ResetsAt) : null,
                    TrayNumber = s.ShowPercentage || !respectToggles ? pct : (int?)null,
                    Utilization = f.Utilization,
                };
                // All sub-toggles off — show a single dot so the click target stays alive.
                if (t.IsEmpty) t.Plain = "·";
                return t;
            }
            if (LastError != null) return new MenuBarTitle { Plain = LastError.TitleSymbol, IsError = true };
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
            if (t.TrayNumber is int n) { text = n.ToString(CultureInfo.InvariantCulture); level = TrayIcon.LevelFor(t.Utilization); }
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
            var tip = TooltipText();
            // NotifyIcon.Text throws past 63 chars on .NET Framework.
            tray.Text = tip.Length > 63 ? tip.Substring(0, 62) + "…" : tip;
        }

        string TooltipText()
        {
            if (LastResponse?.FiveHour is UsageBucket f)
            {
                var reset = Format.TimeRemaining(f.ResetsAt);
                var tip = $"claude-limits · {(int)Math.Round(f.Utilization, MidpointRounding.AwayFromZero)}%";
                if (reset != null) tip += $" · resets in {reset}";
                if (LastError != null) tip += $" · {LastError.TitleSymbol}";
                return tip;
            }
            if (LastError != null) return $"claude-limits · {LastError.TitleSymbol}";
            return "claude-limits";
        }

        // Snapshot capture lives in Snapshot.cs.
        public MenuBarTitle CurrentTitle => currentTitle;

        // ── Refresh + animation ──────────────────────────────────────────────

        /// Apply exponential back-off after a rate-limit response and return the
        /// "do not poll until" deadline. Shared by the poller and the Settings
        /// "Test fetch" button so no entry point can hammer Anthropic during a
        /// cooldown without recording it. 1st 5min, 2nd 10min, 3rd 20min, 4th+
        /// capped at 30min; honours a server Retry-After when it's longer.
        public DateTime RecordRateLimit(double? retry)
        {
            Settings.Shared.ConsecutiveRateLimits += 1;
            int count = Settings.Shared.ConsecutiveRateLimits;
            double exp = Math.Min(300.0 * Math.Pow(2.0, count - 1), 1800.0);
            double secs = Math.Max(retry ?? 0, exp);
            var until = Now.AddSeconds(secs);
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
                    Log.Write($"claude-limits fetch error: {e.FriendlyMessage}");
                }
                if (LastResponse == null) StartRateLimitCycle();
                else StopRateLimitCycle();
            }
            UpdateTitle();
        }

        /// Wave frames: a single peak (█) moves index 0..9 with symmetric falloff.
        /// Palindrome flips this so the peak visibly bounces off the right wall
        /// and returns, instead of jumping back.
        static readonly string[] errorWaveFrames =
        {
            "█▇▆▅▄▃▂▁▁▁",
            "▇█▇▆▅▄▃▂▁▁",
            "▆▇█▇▆▅▄▃▂▁",
            "▅▆▇█▇▆▅▄▃▂",
            "▄▅▆▇█▇▆▅▄▃",
            "▃▄▅▆▇█▇▆▅▄",
            "▂▃▄▅▆▇█▇▆▅",
            "▁▂▃▄▅▆▇█▇▆",
            "▁▁▂▃▄▅▆▇█▇",
            "▁▁▁▂▃▄▅▆▇█",
        };
        static readonly int[] errorWavePalindrome =
            Enumerable.Range(0, errorWaveFrames.Length)
                      .Concat(Enumerable.Range(1, errorWaveFrames.Length - 2).Reverse()).ToArray();
        static readonly int errorPhaseAFrames = errorWavePalindrome.Length;  // 18 — ~1.5s @ 12fps
        const int errorPhaseBFrames = 60;                                    // ~5.0s marquee
        static readonly int errorCycleFrames = errorPhaseAFrames + errorPhaseBFrames;
        /// Cap cold-start error animation. 3 × ~6.5 s = ~19.5 s, then static.
        const int errorMaxCycles = 3;

        /// Bouncing-peak palindrome animation, 12 fps, while a refresh is in flight.
        void StartAnimation()
        {
            animationTimer?.Stop();
            animationFrame = 0;
            animationStartedAt = Now;
            animationGeneration += 1;
            animationTimer = Every(1.0 / 12.0, () =>
            {
                int step = animationFrame % errorWavePalindrome.Length;
                var frame = errorWaveFrames[errorWavePalindrome[step]];
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
            double elapsed = animationStartedAt.HasValue ? (Now - animationStartedAt.Value).TotalSeconds : minAnimationDuration;
            double remaining = Math.Max(0, minAnimationDuration - elapsed);
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
            if (rateLimitAnimFrame >= errorMaxCycles * errorCycleFrames)
            { StopRateLimitCycle(); UpdateTitle(); return; }

            int cyclePos = rateLimitAnimFrame % errorCycleFrames;
            if (cyclePos < errorPhaseAFrames)
            {
                // Phase A: bouncing-peak wave — fits the budget.
                var wave = errorWaveFrames[errorWavePalindrome[cyclePos % errorWavePalindrome.Length]];
                ApplyTitle(new MenuBarTitle { Plain = wave, Mono = true, IsError = true });
            }
            else
            {
                // Phase B: marquee. ~1.17 chars/frame at 12 fps → ~14 chars/sec.
                int phaseFrame = cyclePos - errorPhaseAFrames;
                var core = RateLimitTypewriterText() + "    ";
                int windowWidth = marqueeWindowChars;
                var chars = (new string(' ', windowWidth) + core).ToCharArray();
                int charPos = (int)(phaseFrame * 1.17) % chars.Length;
                var visible = new char[windowWidth];
                for (int i = 0; i < windowWidth; i++) visible[i] = chars[(charPos + i) % chars.Length];
                ApplyTitle(new MenuBarTitle { Plain = new string(visible), Mono = true, IsError = true });
            }
            rateLimitAnimFrame += 1;
        }

        /// Friendly per-error message rendered in the marquee phase.
        string RateLimitTypewriterText()
        {
            var err = LastError;
            if (err == null) return "—";
            switch (err.Kind)
            {
                case AppErrorKind.RateLimited:
                    var until = Settings.Shared.NextAllowedPoll;
                    if (until.HasValue)
                    {
                        int secs = Math.Max(0, (int)(until.Value - Now).TotalSeconds);
                        int m = secs / 60, s = secs % 60;
                        return $"rate limit reached, retry in {(m > 0 ? $"{m}m {s}s" : $"{s}s")}";
                    }
                    return "rate limit reached";
                case AppErrorKind.AuthFailed: return "sign in: run `claude` in terminal";
                case AppErrorKind.TokenNotFound: return "token not configured · open settings";
                case AppErrorKind.Forbidden: return "access forbidden · check account access";
                case AppErrorKind.NetworkUnavailable: return "cannot reach api.anthropic.com";
                case AppErrorKind.RequestTimeout: return "request timed out · trying again soon";
                case AppErrorKind.CommandFailed: return $"shell command failed: {AppError.Prefix(err.Detail, 50)}";
                case AppErrorKind.ParseFailed: return $"parse error: {AppError.Prefix(err.Detail, 50)}";
                default: return $"HTTP {err.StatusCode} from anthropic";
            }
        }

        // ── Flyout text ──────────────────────────────────────────────────────

        /// "Resets @ 3:10 PM · <state-dependent message>" — combines reset clock
        /// with a smoothed burn estimate. The burn rate is time-weighted
        /// (Σ Δpp / Σ Δsec over the current continuous window), NOT an average of
        /// per-pair rates — so Anthropic's lumpy ~5-min updates landing on our
        /// faster poll cadence, sleep/relaunch gaps, and window rollovers can't
        /// inflate it.
        public string FormatResetLine(UsageBucket f)
        {
            var resetDate = Format.ParseISO(f.ResetsAt);
            if (resetDate == null) return "No active 5-hour window — starts on your next Claude request";
            if (resetDate.Value <= Now) return "Window just reset — refreshing soon";
            var resetClock = resetDate.Value.ToLocalTime().ToString("t", CultureInfo.CurrentCulture);
            double minutesToReset = Math.Max(0, (resetDate.Value - Now).TotalMinutes);

            // Capped state — distinct from the API rate-limit error animation.
            // Reaching 100% naturally is normal end-of-window behaviour, not a
            // failure: surface the countdown instead of burn projections.
            if (f.Utilization >= 99.5)
            {
                int m = (int)minutesToReset, h = m / 60, rem = m % 60;
                return $"Capped — resets in {(h > 0 ? $"{h}h {rem}m" : $"{rem}m")} (@ {resetClock})";
            }

            var samples = UsageHistory.Shared.Samples.Where(x => x.Utilization >= 0).ToList();
            if (samples.Count > 30) samples = samples.Skip(samples.Count - 30).ToList();
            if (samples.Count < 3) return $"Resets @ {resetClock} · click to refresh";

            // Time-weighted burn rate over the most recent continuous in-window
            // stretch. A large drop marks a window rollover and a gap far larger
            // than the poll interval (sleep/relaunch) breaks continuity — both
            // reset the accumulation so they can't inflate the rate.
            double maxGap = UsageHistory.PollIntervalSeconds * 2.5;
            double sumPp = 0, sumSec = 0;
            for (int i = 1; i < samples.Count; i++)
            {
                double dPp = samples[i].Utilization - samples[i - 1].Utilization;
                double dSec = samples[i].TimestampUnix - samples[i - 1].TimestampUnix;
                if (dSec <= 0) continue;
                if (dPp < -5 || dSec > maxGap) { sumPp = 0; sumSec = 0; continue; }
                sumPp += Math.Max(0, dPp);   // clamp small downward API jitter to 0
                sumSec += dSec;
            }
            double burnPpHr = sumSec > 0 ? sumPp / sumSec * 3600.0 : 0;
            if (burnPpHr < 0.5)
            {
                // No measurable burn. Distinguish a genuinely idle window from one
                // that's simply too fresh to have moved yet.
                return sumSec < UsageHistory.PollIntervalSeconds * 2
                    ? $"Resets @ {resetClock} · measuring…"
                    : $"Resets @ {resetClock} · idle";
            }

            // Safe pace: the rate that exactly burns the remaining headroom over
            // the remaining window. Below it = will coast in. Above it = early cap.
            double remainingPp = Math.Max(0, 100.0 - f.Utilization);
            double safePpHr = minutesToReset > 0 ? remainingPp / minutesToReset * 60.0 : 0;
            int burnInt = (int)Math.Round(burnPpHr, MidpointRounding.AwayFromZero);
            int safeInt = Math.Max(0, (int)Math.Round(safePpHr, MidpointRounding.AwayFromZero));

            // 5% buffer on the comparison so a steady user doesn't see the warning
            // flap on/off when burn hovers near the safe line.
            if (burnPpHr > safePpHr * 1.05)
            {
                double minsTo100 = remainingPp / burnPpHr * 60.0;
                int h = (int)minsTo100 / 60, m = (int)minsTo100 % 60;
                return $"Resets @ {resetClock} · {burnInt}%/h over safe {safeInt}%/h · 100% in {(h > 0 ? $"{h}h {m}m" : $"{m}m")}";
            }
            return $"Resets @ {resetClock} · {burnInt}%/h · safe ≤ {safeInt}%/h";
        }

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
            var crossings = new[]
            {
                (80, "Claude usage at 80%", "Slow down or risk capping before the window resets."),
                (95, "Claude usage at 95%", "About to cap — finish the current task and pause."),
            };
            foreach (var (threshold, title, body) in crossings)
            {
                if (f.Utilization >= threshold && !fired.Contains(threshold))
                {
                    // Balloon tips surface as Windows toasts on 10/11.
                    tray.ShowBalloonTip(8000, title, body, Forms.ToolTipIcon.Warning);
                    fired.Add(threshold);
                }
            }
            s.NotifiedThresholds = fired;
        }

        /// Single-line top status: "[error · ]Last updated: X · next in Y".
        public string FormatTopStatusLine()
        {
            var prefix = "";
            if (LastError != null)
                prefix = LastError.Kind == AppErrorKind.RateLimited ? "rate-limited · " : $"{LastError.TitleSymbol} · ";
            var lastSeen = LastUpdated.HasValue ? Format.LiveRelativeTime(LastUpdated.Value) : "never";
            string nextClause;
            var np = Settings.Shared.NextAllowedPoll;
            if (LastError?.Kind == AppErrorKind.RateLimited && np.HasValue)
                nextClause = $"next in {Format.NextAttempt(Math.Max(0, (int)(np.Value - Now).TotalSeconds))}";
            else if (LastUpdated == null)
                nextClause = "click to refresh";
            else if (nextPollAt.HasValue)
            {
                int secs = Math.Max(0, (int)(nextPollAt.Value - Now).TotalSeconds);
                if (secs <= 0) nextClause = "next now…";
                else if (secs < 60) nextClause = $"next in {secs}s";
                else nextClause = $"next in {secs / 60}m {secs % 60}s";
            }
            else nextClause = "—";
            return $"{prefix}Last updated: {lastSeen} · {nextClause}";
        }

        // ── Actions ──────────────────────────────────────────────────────────

        public void RefreshAction()
        {
            var until = Settings.Shared.NextAllowedPoll;
            if (until.HasValue && until.Value > Now) return;
            // Share the pill click-storm cooldown so repeated "Refresh now"
            // taps can't bypass the throttle PrimaryClick enforces.
            if (LastManualClickAt.HasValue && (Now - LastManualClickAt.Value).TotalSeconds < ManualClickCooldown)
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
