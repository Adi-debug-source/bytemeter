# Fonts

The dashboard's two typefaces. They travel inside the page as data, so it
looks the same with the network off and still fetches nothing when it opens.

| File | Family | Used for | Licence |
|---|---|---|---|
| `fraunces.woff2` | Fraunces, variable (optical size, weight, softness, wonky) | the big figure and the headings | SIL Open Font License 1.1, see `OFL-Fraunces.txt` |
| `inter-tight.woff2` | Inter Tight, variable (weight) | everything else, including every column of figures, because it has tabular figures and this Fraunces does not | SIL Open Font License 1.1, see `OFL-InterTight.txt` |

The two licence files are the ones Google Fonts publishes with each family,
unchanged. The copyright notices inside the font files themselves read:

- `fraunces.woff2`: Copyright 2020 The Fraunces Project Authors (github.com/undercasetype/Fraunces)
- `inter-tight.woff2`: Copyright 2022 The Inter Project Authors (https://github.com/rsms/inter-tight)

## Where they came from

They are byte for byte copies of the files Tokenmeter embeds in its report,
so the two tools look like a family. Tokenmeter took them from Google Fonts:
the Latin subsets of the variable fonts, as the Google Fonts CSS API serves
them.

| File | Bytes | SHA-256 |
|---|---|---|
| `fraunces.woff2` | 120,800 | `94bb7e04bb1a32237a67935c72526e42a3e52ee4aebd50299802b18a93114251` |
| `inter-tight.woff2` | 44,916 | `83d548cd73ef2e039167db3adb5ea9d7a7870466ffc8a162c9820bc348938aaf` |

## How they reach the page

`Scripts/make_fonts.py` writes them, base64 encoded, into
`Sources/Bytemeter/DashboardFonts.swift`. That file is committed, so building
never needs Python. The app's binary carries the fonts; the bundle's
`Contents/Resources/Fonts/` holds this README, `OFL-Fraunces.txt` and
`OFL-InterTight.txt`.

## Refreshing them

1. Replace a file here, keeping its name. To stay matched with Tokenmeter,
   copy Tokenmeter's. To take one from Google Fonts, ask the CSS API for it
   with a desktop browser's user agent, then download the URL in the
   `/* latin */` block, not `latin-ext`:

        curl -sA "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
          AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36" \
          "https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght,SOFT,WONK@9..144,100..900,0..100,0..1"

   For Inter Tight the family is `Inter+Tight:wght@100..900`.
2. Run `python3 Scripts/make_fonts.py`, then build and look at the dashboard.
3. Update the checksums above. If a font's licence or copyright changes,
   update its licence file and this README too.
