import Foundation

extension DashboardGenerator {

    /// The page shell. Dark by construction rather than by a toggle, one accent
    /// colour, system font stack so nothing is fetched, and figures in tabular
    /// numerals so columns line up.
    static func page(body: String) -> String {
        """
        <!doctype html>
        <html lang="en-GB">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="dark">
        <title>Bytemeter</title>
        <style>
        :root {
          --plane: #0b0d0f;
          --surface: #13171a;
          --surface-2: #171c20;
          --accent: #35a99f;
          --accent-soft: rgba(53,169,159,0.45);
          --ink: #eef1f3;
          --ink-2: #a8b1b8;
          --muted: #6d777e;
          --rule: rgba(255,255,255,0.08);
          --grid: #23282c;
        }
        * { box-sizing: border-box; }
        html { background: var(--plane); }
        body {
          margin: 0;
          padding: 0 28px 56px;
          background: var(--plane);
          /* A hairline weave rather than a gradient wash: texture you notice
             only if you look for it. */
          background-image: repeating-linear-gradient(
            0deg, rgba(255,255,255,0.012) 0 1px, transparent 1px 3px);
          color: var(--ink);
          font: 15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
          font-variant-numeric: tabular-nums;
          max-width: 1180px;
          margin: 0 auto;
          -webkit-font-smoothing: antialiased;
        }
        .masthead {
          display: flex; align-items: flex-end; justify-content: space-between;
          padding: 34px 0 18px; border-bottom: 1px solid var(--rule);
        }
        .brand {
          font-size: 13px; font-weight: 600; letter-spacing: 0.22em; text-transform: uppercase;
          color: var(--accent);
        }
        .brand::after {
          content: ""; display: inline-block; width: 5px; height: 5px; border-radius: 50%;
          background: var(--accent); margin-left: 7px; vertical-align: 2px;
        }
        .meta { text-align: right; font-size: 12.5px; color: var(--ink-2); line-height: 1.5; }
        .muted { color: var(--muted); }

        /* Hero: one big figure, the wider picture beside it. Deliberately not a
           row of matching cards. */
        .hero {
          display: grid; grid-template-columns: 1.35fr 1fr; gap: 46px;
          padding: 40px 0 34px; border-bottom: 1px solid var(--rule); align-items: start;
        }
        .eyebrow { font-size: 12px; letter-spacing: 0.1em; text-transform: uppercase; color: var(--muted); }
        .hero-figure { display: flex; align-items: baseline; gap: 10px; margin: 6px 0 2px; }
        .hero-figure .value { font-size: 76px; line-height: 1; font-weight: 300; letter-spacing: -0.025em; }
        .hero-figure .unit { font-size: 22px; font-weight: 500; color: var(--accent); }
        .hero-sub { font-size: 14px; color: var(--ink-2); }
        .hero-sub .sep { margin: 0 8px; color: var(--muted); }
        .hero-compare { margin-top: 12px; font-size: 13.5px; color: var(--muted); max-width: 42ch; }
        .hero-stats { margin: 0; }
        .hero-stats .stat {
          display: flex; align-items: baseline; justify-content: space-between; gap: 16px;
          padding: 9px 0; border-bottom: 1px solid var(--rule);
        }
        .hero-stats .stat:last-child { border-bottom: none; }
        .hero-stats dt { font-size: 13.5px; color: var(--ink-2); }
        .hero-stats dd { margin: 0; font-size: 15px; font-weight: 500; text-align: right; }
        .hero-stats .qualifier { display: block; font-size: 12px; font-weight: 400; color: var(--muted); }
        .hero-stats .projection dd { color: var(--accent); }

        .panel { padding: 30px 0 26px; border-bottom: 1px solid var(--rule); }
        .panel.feature { background:
          linear-gradient(180deg, rgba(53,169,159,0.035), rgba(53,169,159,0) 70%);
          padding: 30px 22px 26px; margin: 0 -22px; border-radius: 3px; }
        .panel-head { margin-bottom: 18px; }
        .panel-head.tight { margin: 26px 0 10px; }
        .panel h2 { margin: 0; font-size: 15px; font-weight: 600; letter-spacing: 0.01em; }
        .note { margin: 6px 0 0; font-size: 12.5px; color: var(--muted); max-width: 78ch; }
        .row { display: grid; grid-template-columns: 1.55fr 1fr; gap: 40px; }
        .row .panel { border-bottom: none; }
        .side { padding-top: 30px; }

        .chart { width: 100%; height: auto; display: block; }
        .chart.heat { width: 100%; max-width: 980px; }
        .heat-wrap { overflow-x: auto; }
        text.axis { fill: var(--muted); font-size: 11px;
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; }
        .bar rect, .cell rect { transition: opacity 120ms ease; }
        .bar:hover rect, .cell:hover rect { opacity: 0.72; }

        .legend { display: flex; align-items: center; gap: 8px; margin-top: 14px; flex-wrap: wrap; }
        .legend .swatch { display: inline-block; width: 22px; height: 10px; border-radius: 2px; }
        .legend.keys { gap: 22px; }
        .key { display: inline-flex; align-items: center; gap: 8px; font-size: 12.5px; color: var(--ink-2); }
        .key .swatch { width: 14px; height: 10px; border-radius: 2px; }
        .key .solid { background: var(--accent); }
        .key .soft { background: var(--accent-soft); }
        .key .dash { background: repeating-linear-gradient(90deg, var(--ink) 0 5px, transparent 5px 9px); height: 2px; }

        .tables { display: grid; grid-template-columns: 1fr 1fr; gap: 34px; }
        table { width: 100%; border-collapse: collapse; }
        caption { text-align: left; font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase;
          color: var(--muted); padding-bottom: 8px; }
        th { text-align: left; font-size: 11.5px; font-weight: 500; color: var(--muted);
          border-bottom: 1px solid var(--rule); padding: 0 8px 6px 0; }
        td { padding: 7px 8px 7px 0; font-size: 13px; border-bottom: 1px solid rgba(255,255,255,0.04); }
        td.name { max-width: 190px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .num { text-align: right; white-space: nowrap; }
        td.quiet { color: var(--muted); }
        td.share { width: 60px; }
        .tables { column-gap: 28px; }
        td.share span { display: block; height: 5px; border-radius: 3px; background: var(--accent-soft); min-width: 2px; }
        td.empty { color: var(--muted); font-size: 12.5px; }

        .mini { margin: 16px 0 0; }
        .mini div { display: flex; justify-content: space-between; align-items: baseline;
          padding: 7px 0; border-bottom: 1px solid var(--rule); gap: 14px; }
        .mini div:last-child { border-bottom: none; }
        .mini dt { font-size: 13px; color: var(--ink-2); }
        .mini dd { margin: 0; font-size: 13.5px; text-align: right; }
        .mini .qualifier { margin-left: 10px; color: var(--muted); font-size: 12px; }

        .capbar { height: 10px; background: var(--grid); border-radius: 5px; overflow: hidden; }
        .capbar span { display: block; height: 100%; background: var(--accent); }

        footer { padding-top: 34px; }
        .foot-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 46px; }
        footer h3 { margin: 0 0 10px; font-size: 12px; letter-spacing: 0.1em;
          text-transform: uppercase; color: var(--muted); font-weight: 600; }
        footer p { margin: 0 0 10px; font-size: 12.5px; color: var(--ink-2); max-width: 62ch; }
        .events { list-style: none; margin: 0; padding: 0; }
        .events li { padding: 8px 0; border-bottom: 1px solid var(--rule); font-size: 12px; }
        .events .when { display: block; color: var(--muted); }
        .events .kind { display: inline-block; margin: 2px 8px 2px 0; padding: 1px 7px; border-radius: 3px;
          background: rgba(53,169,159,0.14); color: var(--accent); font-size: 11px; letter-spacing: 0.02em; }
        .events .detail { color: var(--ink-2); }
        .foot-bar { display: flex; align-items: center; justify-content: space-between; gap: 20px;
          margin-top: 30px; padding-top: 18px; border-top: 1px solid var(--rule); font-size: 12.5px; }
        .export { color: var(--accent); text-decoration: none; border: 1px solid rgba(53,169,159,0.4);
          padding: 7px 14px; border-radius: 3px; }
        .export:hover { background: rgba(53,169,159,0.1); }

        @media (max-width: 900px) {
          .hero, .row, .tables, .foot-grid { grid-template-columns: 1fr; gap: 26px; }
          .hero-figure .value { font-size: 58px; }
        }
        @media (prefers-reduced-motion: reduce) {
          .bar rect, .cell rect { transition: none; }
        }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
