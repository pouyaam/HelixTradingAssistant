# Changelog

All notable changes to the Helix Trading App project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.0] - 2026-07-29

### Added
- **Chart Appearance & Color Themes**: Introduced 3 selectable color themes for candles, wicks, and volume bars across macOS and iPad targets:
  - **Green & Red**: Classic trading bullish green (`#21C768`) and bearish red (`#F04545`).
  - **Blue & Red**: Modern TradingView-style blue (`#2962FF`) and bearish red (`#F04545`).
  - **Black & White**: Monochrome institutional style (white `#F2F5FA` bullish & dark slate `#596173` bearish for high contrast).
- **Theme Controls**:
  - Segmented theme selector in **Settings** -> **General** -> **Chart appearance & theme**.
  - Quick theme selector in the chart **Layers** popover.
  - **Chart Theme** sub-menu in the right-click chart context menu.
- **Multi-Chart Grid & iPad Sync**: Themes persist in `@AppStorage("dashboard.chartTheme")` and update all grid panes and iPad views in real time.

## [1.5.0] - 2026-07-15

### Added
- On-chart position planning tool with draggable entry/SL/TP levels and live lot sizing.
- Four new order-block indicators (Ranked OB, Volume-Filtered OB, Ichimoku Cloud, Ichimoku OBs).
- Economic calendar news flags plotted directly on the chart time axis.
- Volume Profile overhaul (Session, ZigZag, and Visible Range modes).

## [1.4.0] - 2026-07-01

### Added
- Multiple journals support (Prop challenge, Personal account, Backtests).
- In-app update checker integrating with GitHub Releases.
- OpenCode engine support for local/remote LLM execution.
