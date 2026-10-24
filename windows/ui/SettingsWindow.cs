using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
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

    /// Utilization history: coral line, soft fill; empty below 2 samples (never faked).
    sealed class TopWaveView : FrameworkElement
    {

        protected override void OnRender(DrawingContext dc)
        {
            var samples = WaveValues(UsageHistory.Shared.Samples);   // logic/core.pl
            if (samples.Count == 0) return;

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

    }

    /// Standalone (not in the Window) so snapshots can lay it out offscreen in either theme.
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
        /// The Display toggles in order, each bound to the Settings property it writes.
        static readonly (string label, string prop)[] toggles =
        {
            ("Percentage", "ShowPercentage"), ("Burn-rate wave", "ShowWave"), ("Reset countdown", "ShowResetTime"),
            ("Floating pill by the tray", "ShowPill"), ("Open at login", "LaunchAtStartup"),
        };
        CheckBox[] switches;
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
            foreach (var h in new[] { new GridLength(56), GridLength.Auto, GridLength.Auto, GridLength.Auto }) Root.RowDefinitions.Add(new RowDefinition { Height = h });

            Root.Children.Add(new TopWaveView());

            // ── Token source ────────────────────────────────────────────────
            var modes = new[] { "Auto-detect", "Custom file path", "Custom shell command" };
            modeButtons = modes.Select((m, i) => new RadioButton
            {
                Content = m, GroupName = "tokenSource" + GetHashCode(),
                Margin = new Thickness(i == 0 ? 0 : 4, 0, 0, 0),
            }).ToArray();
            var segs = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var b in modeButtons)
            {
                b.SetResourceReference(FrameworkElement.StyleProperty, "Segment");
                b.Checked += (_, __) => ModeChanged();
                segs.Children.Add(b);
            }

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
            switches = toggles.Select(_ => MakeSwitch()).ToArray();
            var toggleRows = VStack(2, toggles.Select((t, i) => ToggleRow(t.label, switches[i])).ToArray());

            updateBtn = new Button { Content = "Check for updates", HorizontalAlignment = HorizontalAlignment.Left };
            updateBtn.Click += (_, __) => { if (updateBtnPerformsUpdate) PerformUpdate(); else CheckForUpdates(); };

            statusLabel = new TextBlock { Text = " ", TextWrapping = TextWrapping.Wrap, Width = controlsWidth };
            statusLabel.SetResourceReference(TextBlock.ForegroundProperty, "FgDim");

            var menuSection = Section(MakeMenubarArt(), VStack(8, toggleRows, updateBtn, statusLabel));

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
            by.Click += (_, __) => Platform.OpenUrl("https://github.com/ibrarwtf");
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
            for (int i = 0; i < toggles.Length; i++) switches[i].IsChecked = (bool)typeof(Settings).GetProperty(toggles[i].prop).GetValue(s);
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
            // icon column 150 + gap 18 + controls 460, so the rule stops at the toggles.
            var b = new Border { Height = 1, Width = 628, HorizontalAlignment = HorizontalAlignment.Left };
            b.SetResourceReference(Border.BackgroundProperty, "Divider");
            return b;
        }

        static FrameworkElement Section(FrameworkElement icon, FrameworkElement controls)
        {
            var g = new Grid();
            foreach (var w in new[] { 150, 18, controlsWidth }) g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w) });
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

        /// credentials.json glyph: bordered rect with a status dot.
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

        /// null = not yet probed (gray); true / false = token reachable / failed (green / red pulse).
        void SetCredentialsDot(bool? ok)
        {
            credentialsDot.BeginAnimation(UIElement.OpacityProperty, null);
            credentialsDot.Opacity = 1;
            credentialsDot.SetResourceReference(Shape.FillProperty, ok == null ? "FgDim" : ok.Value ? "Green" : "Red");
            if (ok == null) return;
            credentialsDot.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1.0, 0.25, TimeSpan.FromSeconds(1.4))
            {
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
                EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
            });
        }

        /// Updates the dot on open; see dot_on_open in logic/core.pl.
        async void RefreshCredentialsDot()
        {
            switch (DotOnOpen(app.LastResponse != null, Settings.Shared.LastSuccessfulPoll, app.IsRefreshing,
                              Settings.Shared.NextAllowedPoll, app.LastManualClickAt, DateTime.UtcNow))
            {
                case Dot.Connected: SetCredentialsDot(true); return;
                case Dot.Unverified: SetCredentialsDot(null); return;
            }
            app.LastManualClickAt = DateTime.UtcNow;
            var r = await Api.FetchUsageAsync();
            if (r != null) SetCredentialsDot(r.IsSuccess);
        }

        public void DidAppear()
        {
            RefreshCredentialsDot();
            ApplyUpdateButtonState();
        }

        /// Always-dark pill mock, like the Mac's, so toggles preview the real thing.
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
            if (mockContainer == null || switches?.Contains(null) != false) return;
            var t = new MenuBarTitle
            {
                Pct = switches[0].IsChecked == true ? "12%" : null,
                Wave = switches[1].IsChecked == true ? "▆▇█▇▆▆▅▅▄▃" : null,
                Reset = switches[2].IsChecked == true ? "3:26" : null,
            };
            if (t.IsEmpty) t.Plain = "·";
            var v = PillView.Build(t);
            v.HorizontalAlignment = HorizontalAlignment.Center;
            mockContainer.Child = v;
        }

        void ModeChanged()
        {
            if (hintLabel == null || fileRow == null || shellRow == null) return;
            var mode = SelectedMode;
            hintLabel.Text = SourceHint(mode, true, Token.KnownCredentialPaths.Last(p => p.StartsWith("~")));
            fileRow.Visibility = mode == TokenSource.File ? Visibility.Visible : Visibility.Collapsed;
            shellRow.Visibility = mode == TokenSource.Shell ? Visibility.Visible : Visibility.Collapsed;
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
            for (int i = 0; i < toggles.Length; i++) typeof(Settings).GetProperty(toggles[i].prop).SetValue(s, switches[i].IsChecked == true);
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

        /// A known newer version turns "Check for updates" into "Update to vX".
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
            // Covers the gap while the tray icon is gone and the new exe starts.
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
                Platform.OpenUrl(Updates.ReleasesPage + "/latest");
            }
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
            // No diagnostic hits during an active 429 window.
            var wait = WaitStatus(Settings.Shared.NextAllowedPoll, DateTime.UtcNow);
            if (wait != null) { SetStatus(wait); return; }
            SetStatus("Testing…");
            var r = await Api.FetchUsageAsync();
            if (r == null) return;
            if (r.IsSuccess)
            {
                SetStatus(TestStatus(r.Value.FiveHour?.Utilization), "Fg");
                SetCredentialsDot(true);
            }
            else
            {
                // Feed the 429 into the shared back-off so testing can't reset the cooldown.
                if (r.Error.Kind == AppErrorKind.RateLimited) app.RecordRateLimit(r.Error.RetryAfter);
                SetStatus(FriendlyMessage(r.Error), "Fg");
                SetCredentialsDot(false);
            }
        }
    }
}
