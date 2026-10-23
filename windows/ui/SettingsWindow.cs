using System;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

using static ClaudeLimits.Logic;

namespace ClaudeLimits
{
    sealed class SettingsWindow : Window
    {
        public SettingsWindow(TrayApp app, Action onSave)
        {
            Title = "claude-limits — Settings";
            Width = SettingsView.WindowWidth;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.CanMinimize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            try { Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(Platform.ExePath)); } catch { }

            var view = new SettingsView(app, onSave, close: Close);
            Content = view.Root;
            Theme.Apply(view.Root, Theme.AppsDark);
            view.Root.SetResourceReference(Panel.BackgroundProperty, "Bg");

            SourceInitialized += (_, __) => Native.SetDarkTitleBar(new WindowInteropHelper(this).Handle, Theme.AppsDark);
            Action onTheme = () =>
            {
                Theme.Apply(view.Root, Theme.AppsDark);
                Native.SetDarkTitleBar(new WindowInteropHelper(this).Handle, Theme.AppsDark);
            };
            Theme.Changed += onTheme;
            Closed += (_, __) => Theme.Changed -= onTheme;
            ContentRendered += (_, __) => view.DidAppear();
            Activated += (_, __) => view.ApplyUpdateButtonState();
        }
    }

    /// Historic utilization plot across the top of Settings — coral line with soft
    /// fill below. Real data only; leaves the strip empty when there's < 2
    /// samples instead of faking a curve.
    sealed class TopWaveView : FrameworkElement
    {
        /// Three repetitions visually echoes the rolling-window concept.
        const int tileCount = 3;
        const int smoothWindow = 3;

        protected override void OnRender(DrawingContext dc)
        {
            // Treat error sentinels (utilization < 0) as 0 — flat dip in the line.
            var raw = UsageHistory.Shared.Samples.Select(x => x.Utilization < 0 ? 0.0 : x.Utilization).ToList();
            if (raw.Count < 2) return;
            var smoothed = MovingAverage(raw, smoothWindow);
            // Tile the smoothed pattern so the rolling-window cadence reads even
            // with one session of data.
            var samples = Enumerable.Repeat(smoothed, tileCount).SelectMany(x => x).ToList();

            double padTop = 4, padBottom = 1;
            double usable = ActualHeight - padTop - padBottom;
            double width = ActualWidth;
            double dx = width / (samples.Count - 1);
            var pts = samples.Select((v, i) => new Point(i * dx, ActualHeight - (padBottom + Math.Max(0, Math.Min(100, v)) / 100.0 * usable))).ToList();

            var line = (TryFindResource("Coral") as SolidColorBrush)?.Color ?? Color.FromRgb(0xD9, 0x77, 0x55);
            var fillTop = (TryFindResource("CoralFill") as SolidColorBrush)?.Color ?? Color.FromArgb(0x59, 0xFF, 0x99, 0x66);
            var fillBottom = Color.FromArgb(0, fillTop.R, fillTop.G, fillTop.B);

            var fill = new StreamGeometry();
            using (var ctx = fill.Open())
            {
                ctx.BeginFigure(new Point(0, ActualHeight), true, true);
                ctx.PolyLineTo(pts.Concat(new[] { new Point(width, ActualHeight) }).ToList(), true, true);
            }
            dc.DrawGeometry(new LinearGradientBrush(fillTop, fillBottom, 90), null, fill);

            var stroke = new StreamGeometry();
            using (var ctx = stroke.Open())
            {
                ctx.BeginFigure(pts[0], false, false);
                ctx.PolyLineTo(pts.Skip(1).ToList(), true, true);
            }
            dc.DrawGeometry(null, new Pen(new SolidColorBrush(line), 1.4) { LineJoin = PenLineJoin.Round }, stroke);
        }

        /// Centred moving-average smoothing. Output length == input length.
        static System.Collections.Generic.List<double> MovingAverage(System.Collections.Generic.List<double> v, int window)
        {
            if (v.Count <= 1 || window <= 1) return v;
            int half = window / 2;
            var outp = new System.Collections.Generic.List<double>(v.Count);
            for (int i = 0; i < v.Count; i++)
            {
                int lo = Math.Max(0, i - half), hi = Math.Min(v.Count - 1, i + half);
                double sum = 0; for (int j = lo; j <= hi; j++) sum += v[j];
                outp.Add(sum / (hi - lo + 1));
            }
            return outp;
        }
    }

    /// Settings content. Built standalone (not inside the Window class) so the
    /// snapshot renderer can lay it out offscreen in either theme.
    sealed class SettingsView
    {
        public const double WindowWidth = 720;
        const double controlsWidth = 460;

        public readonly Grid Root = new Grid();
        readonly TrayApp app;
        readonly Action onSave, close;

        RadioButton[] modeButtons;
        TextBox fileField, shellField;
        TextBlock hintLabel, statusLabel;
        FrameworkElement fileRow, shellRow;
        CheckBox pctSwitch, waveSwitch, resetSwitch, pillSwitch, launchSwitch;
        Border mockContainer;
        Button updateBtn;
        bool updateBtnPerformsUpdate;
        Ellipse credentialsDot;

        public SettingsView(TrayApp app, Action onSave, Action close)
        {
            this.app = app; this.onSave = onSave; this.close = close;
            Build();
        }

        void Build()
        {
            Root.Width = WindowWidth;
            Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(56) });
            Root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            Root.Children.Add(new TopWaveView());

            // ── Token source ────────────────────────────────────────────────
            var modes = new[] { "Auto-detect", "Custom file path", "Custom shell command" };
            modeButtons = modes.Select((m, i) => new RadioButton
            {
                Content = m, GroupName = "tokenSource" + GetHashCode(),
                Margin = new Thickness(i == 0 ? 0 : 4, 0, 0, 0),
            }).ToArray();
            foreach (var b in modeButtons)
            {
                b.SetResourceReference(FrameworkElement.StyleProperty, "Segment");
                b.Checked += (_, __) => ModeChanged();
            }
            var segs = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var b in modeButtons) segs.Children.Add(b);

            hintLabel = Small("");
            hintLabel.Width = controlsWidth;

            fileField = new TextBox { Width = 290, Tag = @"~\.claude\.credentials.json" };
            var browse = new Button { Content = "Browse…", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
            browse.Click += (_, __) => BrowseForFile();
            fileRow = Row("File path", fileField, browse);

            shellField = new TextBox { Width = 360, Tag = Token.ShellCommandExample };
            shellRow = Row("Shell command", shellField);

            var tokenControls = VStack(8, Row("Token source", segs), hintLabel, fileRow, shellRow);
            var tokenSection = Section(MakeKeyArt("credentials.json"), tokenControls);

            // ── Display + General (merged, like the Mac's Menu bar section) ──
            pctSwitch = MakeSwitch(); waveSwitch = MakeSwitch(); resetSwitch = MakeSwitch();
            pillSwitch = MakeSwitch(); launchSwitch = MakeSwitch();
            var toggles = VStack(2,
                ToggleRow("Percentage", pctSwitch),
                ToggleRow("Burn-rate wave", waveSwitch),
                ToggleRow("Reset countdown", resetSwitch),
                ToggleRow("Floating pill by the tray", pillSwitch),
                ToggleRow("Open at login", launchSwitch));

            updateBtn = new Button { Content = "Check for updates", HorizontalAlignment = HorizontalAlignment.Left };
            updateBtn.Click += (_, __) => { if (updateBtnPerformsUpdate) PerformUpdate(); else CheckForUpdates(); };

            statusLabel = new TextBlock { Text = " ", TextWrapping = TextWrapping.Wrap, Width = controlsWidth };
            statusLabel.SetResourceReference(TextBlock.ForegroundProperty, "FgDim");

            var menuSection = Section(MakeMenubarArt(), VStack(8, toggles, updateBtn, statusLabel));

            var sections = VStack(14, tokenSection, Divider(), menuSection);
            sections.Margin = new Thickness(24, 12, 24, 0);
            Grid.SetRow(sections, 1);
            Root.Children.Add(sections);

            // ── Action buttons row [Test fetch] [Save] ──────────────────────
            var testBtn = new Button { Content = "Test fetch" };
            testBtn.Click += (_, __) => TestFetch();
            var saveBtn = new Button { Content = "Save", IsDefault = true, Margin = new Thickness(8, 0, 0, 0), MinWidth = 80 };
            saveBtn.SetResourceReference(FrameworkElement.StyleProperty, "PrimaryButton");
            saveBtn.Click += (_, __) => Save();
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(24, 18, 24, 12) };
            buttons.Children.Add(testBtn);
            buttons.Children.Add(saveBtn);
            Grid.SetRow(buttons, 2);
            Root.Children.Add(buttons);

            // ── Footer (author | version) ───────────────────────────────────
            var footer = new Grid { Margin = new Thickness(24, 0, 24, 14) };
            var by = new Button { Style = null, HorizontalAlignment = HorizontalAlignment.Center };
            by.SetResourceReference(FrameworkElement.StyleProperty, "LinkButton");
            var byText = new TextBlock { Text = "made by ibr", FontSize = 11, TextDecorations = TextDecorations.Underline };
            byText.SetResourceReference(TextBlock.ForegroundProperty, "Link");
            by.Content = byText;
            by.Click += (_, __) => Open("https://github.com/ibrarwtf");
            var ver = Small($"v{Platform.Version}");
            ver.SetResourceReference(TextBlock.ForegroundProperty, "FgFaint");
            ver.HorizontalAlignment = HorizontalAlignment.Right;
            footer.Children.Add(by);
            footer.Children.Add(ver);
            Grid.SetRow(footer, 3);
            Root.Children.Add(footer);

            var s = Settings.Shared;
            modeButtons[(int)s.TokenSource].IsChecked = true;
            fileField.Text = s.CustomFilePath;
            shellField.Text = s.CustomShellCommand;
            pctSwitch.IsChecked = s.ShowPercentage;
            waveSwitch.IsChecked = s.ShowWave;
            resetSwitch.IsChecked = s.ShowResetTime;
            pillSwitch.IsChecked = s.ShowPill;
            launchSwitch.IsChecked = s.LaunchAtStartup;
            ApplyMockToToggles();
            ModeChanged();
            ApplyUpdateButtonState();
        }

        // ── Layout helpers ──────────────────────────────────────────────────

        static TextBlock Small(string text)
        {
            var t = new TextBlock { Text = text, FontSize = 11, TextWrapping = TextWrapping.Wrap };
            t.SetResourceReference(TextBlock.ForegroundProperty, "FgDim");
            return t;
        }

        static StackPanel VStack(double spacing, params FrameworkElement[] views)
        {
            var s = new StackPanel();
            for (int i = 0; i < views.Length; i++)
            {
                if (i > 0) views[i].Margin = new Thickness(views[i].Margin.Left, spacing, views[i].Margin.Right, views[i].Margin.Bottom);
                s.Children.Add(views[i]);
            }
            return s;
        }

        static FrameworkElement Row(string label, params FrameworkElement[] controls)
        {
            var s = new StackPanel { Orientation = Orientation.Horizontal };
            s.Children.Add(new TextBlock { Text = label, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
            foreach (var c in controls) { c.VerticalAlignment = VerticalAlignment.Center; s.Children.Add(c); }
            return s;
        }

        static FrameworkElement Divider()
        {
            // Width matches the section content: icon column (150) + gap (18) +
            // controls (460), so the rule doesn't overshoot the toggle column.
            var b = new Border { Height = 1, Width = 628, HorizontalAlignment = HorizontalAlignment.Left };
            b.SetResourceReference(Border.BackgroundProperty, "Divider");
            return b;
        }

        static FrameworkElement Section(FrameworkElement icon, FrameworkElement controls)
        {
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(controlsWidth) });
            icon.Margin = new Thickness(14, 0, 0, 0);
            icon.HorizontalAlignment = HorizontalAlignment.Left;
            icon.VerticalAlignment = VerticalAlignment.Top;
            g.Children.Add(icon);
            Grid.SetColumn(controls, 2);
            g.Children.Add(controls);
            return g;
        }

        CheckBox MakeSwitch()
        {
            var sw = new CheckBox();
            sw.Checked += (_, __) => ApplyMockToToggles();
            sw.Unchecked += (_, __) => ApplyMockToToggles();
            return sw;
        }

        /// "[label] ........... [switch]"; clicking the label flips the switch too.
        static FrameworkElement ToggleRow(string label, CheckBox sw)
        {
            var d = new DockPanel { Width = controlsWidth, Height = 28, Background = Brushes.Transparent };
            DockPanel.SetDock(sw, Dock.Right);
            d.Children.Add(sw);
            d.Children.Add(new TextBlock { Text = label, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
            d.MouseLeftButtonUp += (_, e) => { if (!sw.IsMouseOver) sw.IsChecked = !(sw.IsChecked ?? false); };
            return d;
        }

        /// Minimal credentials.json glyph: bordered rect with a status dot.
        FrameworkElement MakeKeyArt(string text)
        {
            var g = new Grid { Width = 110, Height = 60 };
            var border = new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1) };
            border.SetResourceReference(Border.BorderBrushProperty, "FgFaint");
            g.Children.Add(border);
            credentialsDot = new Ellipse { Width = 5, Height = 5, Margin = new Thickness(8, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
            credentialsDot.SetResourceReference(Shape.FillProperty, "FgDim");
            g.Children.Add(credentialsDot);
            var label = Small(text);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            label.VerticalAlignment = VerticalAlignment.Bottom;
            label.Margin = new Thickness(0, 0, 0, 8);
            g.Children.Add(label);
            return g;
        }

        /// Three states: gray = unverified (initial / not yet probed),
        /// green-pulsing = token reachable, red-pulsing = token verified failed.
        enum CredentialsState { Unverified, Connected, Disconnected }

        void SetCredentialsState(CredentialsState state)
        {
            credentialsDot.BeginAnimation(UIElement.OpacityProperty, null);
            credentialsDot.Opacity = 1;
            if (state == CredentialsState.Unverified)
            {
                credentialsDot.SetResourceReference(Shape.FillProperty, "FgDim");
                return;
            }
            credentialsDot.SetResourceReference(Shape.FillProperty, state == CredentialsState.Connected ? "Green" : "Red");
            credentialsDot.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1.0, 0.25, TimeSpan.FromSeconds(1.4))
            {
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
                EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
            });
        }

        void SetCredentialsDotConnected(bool connected) =>
            SetCredentialsState(connected ? CredentialsState.Connected : CredentialsState.Disconnected);

        /// Quick token-reachability probe; updates the dot. Settings-open reuses
        /// recent app state so merely opening the window doesn't burn a usage call.
        async void RefreshCredentialsDot()
        {
            if (app.LastResponse != null) { SetCredentialsDotConnected(true); return; }
            var last = Settings.Shared.LastSuccessfulPoll;
            if (last.HasValue && (DateTime.UtcNow - last.Value).TotalSeconds < PollInterval)
            { SetCredentialsDotConnected(true); return; }
            if (app.IsRefreshing) { SetCredentialsState(CredentialsState.Unverified); return; }
            var until = Settings.Shared.NextAllowedPoll;
            if (until.HasValue && until.Value > DateTime.UtcNow) { SetCredentialsState(CredentialsState.Unverified); return; }
            // Throttle the probe so reopening Settings in a tight loop can't
            // fire an ungated fetch per reopen (cold-start / prior non-429
            // error state, where nothing above short-circuits).
            if (app.LastManualClickAt.HasValue && (DateTime.UtcNow - app.LastManualClickAt.Value).TotalSeconds < ClickCooldown)
            { SetCredentialsState(CredentialsState.Unverified); return; }
            app.LastManualClickAt = DateTime.UtcNow;
            var r = await Api.FetchUsageAsync();
            if (r != null) SetCredentialsDotConnected(r.IsSuccess);
        }

        public void DidAppear()
        {
            RefreshCredentialsDot();
            ApplyUpdateButtonState();
        }

        /// Tiny mock of the pill. Always dark, like the Mac's menu-bar mock, so
        /// toggle changes preview the real thing.
        FrameworkElement MakeMenubarArt()
        {
            mockContainer = new Border { MinWidth = 130, Height = 28, CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1) };
            var dark = Theme.Make(true);
            mockContainer.Resources = dark;
            mockContainer.Background = (Brush)dark["PillBg"];
            mockContainer.BorderBrush = (Brush)dark["PillBorder"];
            return mockContainer;
        }

        /// Mirror toggle state into the live preview mock.
        void ApplyMockToToggles()
        {
            if (mockContainer == null || pctSwitch == null || waveSwitch == null || resetSwitch == null) return;
            var t = new MenuBarTitle
            {
                Pct = pctSwitch.IsChecked == true ? "12%" : null,
                Wave = waveSwitch.IsChecked == true ? "▆▇█▇▆▆▅▅▄▃" : null,
                Reset = resetSwitch.IsChecked == true ? "3:26" : null,
            };
            if (t.IsEmpty) t.Plain = "·";
            var v = PillView.Build(t);
            v.HorizontalAlignment = HorizontalAlignment.Center;
            mockContainer.Child = v;
        }

        void ModeChanged()
        {
            if (hintLabel == null || fileRow == null || shellRow == null) return;
            switch (SelectedMode)
            {
                case TokenSource.Auto:
                    hintLabel.Text = $@"Reads the credentials file Claude Code writes when you sign in ({Token.KnownCredentialPaths.Last(p => p.StartsWith("~"))}, or under CLAUDE_CONFIG_DIR when that's set).";
                    fileRow.Visibility = Visibility.Collapsed;
                    shellRow.Visibility = Visibility.Collapsed;
                    break;
                case TokenSource.File:
                    hintLabel.Text = "Path to a Claude credentials JSON or a file containing just the access token.";
                    fileRow.Visibility = Visibility.Visible;
                    shellRow.Visibility = Visibility.Collapsed;
                    break;
                case TokenSource.Shell:
                    hintLabel.Text = "A PowerShell command that prints credentials JSON or a token to stdout. Useful when Claude runs in WSL (wsl cat ~/.claude/.credentials.json), Docker, or on a remote machine over SSH.";
                    fileRow.Visibility = Visibility.Collapsed;
                    shellRow.Visibility = Visibility.Visible;
                    break;
            }
        }

        TokenSource SelectedMode
        {
            get
            {
                int i = Array.FindIndex(modeButtons, b => b.IsChecked == true);
                return i < 0 ? TokenSource.Auto : (TokenSource)i;
            }
        }

        void BrowseForFile()
        {
            var dlg = new Microsoft.Win32.OpenFileDialog
            {
                Title = "Choose a Claude credentials file",
                Filter = "Credentials (*.json)|*.json|All files (*.*)|*.*",
                InitialDirectory = System.IO.Path.GetDirectoryName(Token.ExpandPath(@"~\.claude\.credentials.json")),
            };
            if (dlg.ShowDialog() == true) fileField.Text = dlg.FileName;
        }

        void Collect()
        {
            var s = Settings.Shared;
            s.TokenSource = SelectedMode;
            s.CustomFilePath = fileField.Text;
            s.CustomShellCommand = shellField.Text;
            s.ShowPercentage = pctSwitch.IsChecked == true;
            s.ShowWave = waveSwitch.IsChecked == true;
            s.ShowResetTime = resetSwitch.IsChecked == true;
            s.ShowPill = pillSwitch.IsChecked == true;
            s.LaunchAtStartup = launchSwitch.IsChecked == true;
        }

        void SetStatus(string text, string fgKey = "FgDim")
        {
            statusLabel.Text = text;
            statusLabel.SetResourceReference(TextBlock.ForegroundProperty, fgKey);
        }

        async void CheckForUpdates()
        {
            SetStatus("Checking for updates…");
            var (latest, err) = await app.CheckForLatestRelease();
            SetStatus(UpdateStatus(latest?.TagName, err?.Message, Platform.Version), err != null ? "FgDim" : latest != null ? "Orange" : "Fg");
            if (err == null) ApplyUpdateButtonState();
        }

        /// Reflect known update availability on the action button: a pending update
        /// turns "Check for updates" into "Update to vX" (which performs it). Driven
        /// by the app's cached LatestVersionAvailable (set at launch + daily).
        public void ApplyUpdateButtonState()
        {
            if (updateBtn == null) return;
            var latest = app.LatestVersionAvailable;
            updateBtnPerformsUpdate = latest != null;
            updateBtn.Content = UpdateButton(latest?.TagName);
        }

        async void PerformUpdate()
        {
            var latest = app.LatestVersionAvailable;
            if (latest == null) { CheckForUpdates(); return; }
            SetStatus(UpdatingStatus(latest.TagName));
            updateBtn.IsEnabled = false;
            // Breadcrumb for the brief gap where the tray icon disappears while
            // the new exe starts.
            app.NotifyUpdating(latest.TagName);
            try
            {
                await System.Threading.Tasks.Task.Run(() => SelfUpdate.InstallAsync(latest));
                SelfUpdate.Relaunch();
                app.Quit();
            }
            catch (Exception e)
            {
                Log.Write($"self-update failed: {e.Message}");
                SetStatus($"Update failed ({e.Message}). Opening the releases page instead.", "Orange");
                updateBtn.IsEnabled = true;
                Open(Updates.ReleasesPage + "/latest");
            }
        }

        static void Open(string url)
        {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
        }

        void Save()
        {
            Collect();
            onSave?.Invoke();
            close?.Invoke();
        }

        async void TestFetch()
        {
            Collect();
            // Respect the rate-limit cooldown — a diagnostic button shouldn't hit
            // Anthropic during an active 429 window.
            var until = Settings.Shared.NextAllowedPoll;
            if (until.HasValue && until.Value > DateTime.UtcNow)
            {
                SetStatus(WaitStatus(Math.Max(0, (int)(until.Value - DateTime.UtcNow).TotalSeconds)));
                return;
            }
            SetStatus("Testing…");
            var r = await Api.FetchUsageAsync();
            if (r == null) return;
            if (r.IsSuccess)
            {
                SetStatus(TestStatus(r.Value.FiveHour?.Utilization), "Fg");
                SetCredentialsDotConnected(true);
            }
            else
            {
                // Feed a 429 into the shared back-off so a test fetch can't
                // silently reset Anthropic's cooldown while the poller waits.
                if (r.Error.Kind == AppErrorKind.RateLimited) app.RecordRateLimit(r.Error.RetryAfter);
                SetStatus(FriendlyMessage(r.Error), "Fg");
                SetCredentialsDotConnected(false);
            }
        }
    }
}
