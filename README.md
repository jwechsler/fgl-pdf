# fgl-pdf

Render **Boca Systems FGL** (Friendly Ghost Language — the command language of Boca
thermal ticket printers) to PDF, in pure Ruby.

It ships three things:

- **`FglPdf`** — a library: FGL bytes in, one PDF per ticket out.
- **`fgl2pdf`** — a command-line converter for captured FGL files.
- **`fgl-printer`** — a *virtual Boca printer*: a TCP server on port 9100 that accepts the
  same bytes a real printer would and spools each ticket to a numbered PDF. Point a
  ticketing system at it to develop and test without paper.

## Install

From git (not yet on rubygems.org):

```ruby
# Gemfile
gem 'fgl_pdf', git: 'https://github.com/jwechsler/fgl-pdf'
```

or build it yourself:

```sh
git clone https://github.com/jwechsler/fgl-pdf && cd fgl-pdf
gem build fgl_pdf.gemspec && gem install ./fgl_pdf-*.gem
```

Requires Ruby ≥ 3.2. Dependencies (prawn, barby, rqrcode, chunky_png) are pure Ruby.

## Library

```ruby
require 'fgl_pdf'

FglPdf.render(File.binread('order.fgl')).each_with_index do |rendered, i|
  File.binwrite(format('ticket-%03d.pdf', i + 1), rendered.pdf)
  rendered.ticket.warnings.each { |w| warn w }
end
```

`FglPdf.render(bytes, config:, logo_store:, counter:)` returns `RenderedTicket(ticket, pdf)`
structs. A ticket is complete at a print command (`<p>`, `<q>`, `<z>`, FF, …); data after
the last print command is discarded, as on a real printer.

For streaming input or more control, use the parts directly:

```ruby
config      = FglPdf::Config.new(dpi: 300, width_in: 2.0, length_in: 5.5)
interpreter = FglPdf::Interpreter.new(config: config, logo_store: FglPdf::LogoStore.new,
                                      counter: FglPdf::Counter.new)
renderer    = FglPdf::Renderer::Pdf.new(config)

tickets = interpreter.feed(chunk)          # call repeatedly; returns completed tickets
pdf     = renderer.render_many(tickets)    # or renderer.render(ticket) per ticket
interpreter.pending?                       # unprinted data still buffered?
```

`LogoStore.new(dir: path)` persists downloaded logos between runs; `Counter` holds the
ticket counter used by `<PC>`/`<TC>`.

## fgl2pdf

```sh
fgl2pdf INPUT.fgl [-o DIR] [--single] [--dpi N] [--width-in IN] [--length-in IN]
                  [--font-dir DIR] [--debug-grid] [--annotate] [--strict]
```

- Writes `BASENAME-001.pdf`, `BASENAME-002.pdf`, … to `DIR` (default: current directory),
  or a single multi-page `BASENAME.pdf` with `--single`. Written paths go to stdout.
- `INPUT` may be `-` to read stdin (basename `stdin`).
- Warnings go to stderr as `BASENAME-001: <warning>`.
- Exit status: 0 on success, 1 if the input contains no complete ticket, 2 on a read error
  or a `--strict` failure, 64 on bad usage.

Each run starts with an empty logo store and counter, so a job that prints a logo must
contain its logo download (concatenate the files: `cat logo.fgl order.fgl | fgl2pdf -`).

## fgl-printer (virtual printer)

```sh
fgl-printer --out ./tickets [--port 9100] [--host 0.0.0.0] [--verbose] [render options]
```

- Every connection gets its own interpreter (fonts, rotation, position never leak between
  clients); downloaded logos and the ticket counter are shared and persisted in
  `OUT/.printer/`, like a real printer's flash memory, so a logo downloaded once (for example
  at application start-up) is available to later jobs and restarts.
- Logs one line per ticket to stdout, e.g. `ticket 000012 (3 warnings) from 172.18.0.5:51234`;
  `--verbose` adds the warnings themselves and status queries.
- Data left without a print command when a connection closes is discarded and logged.
- A ticket that fails to render does not stop the server: its `.fgl` and an index line with
  an `error` field are still written.
- Status queries (`<S1>` etc.) get no reply. (`FglPdf::PrinterServer` accepts a
  `status_reply:` byte string for hosts that wait for one; it is not a byte-accurate Boca
  status.)
- `SIGINT`/`SIGTERM` stop it gracefully (open connections get 2 s to finish).

### Docker

```sh
docker build -t fgl-printer .
docker run --rm -p 9100:9100 -v "$PWD/tickets:/tickets" fgl-printer
```

Pass options as environment variables (`-e FGL_PDF_DPI=203`) or by overriding the command
(`docker run … fgl-printer fgl-printer --out /tickets --verbose`). Point your application's
printer address at the container's host/IP and port 9100.

### Output layout

```
tickets/
├── 000001.pdf        rendered ticket (one file per copy)
├── 000001.fgl        exact bytes that produced it
├── 000002.pdf
├── 000002.fgl
├── index.jsonl       one JSON line per spooled copy
└── .printer/
    ├── seq.lock      numbering lock
    ├── counter       ticket counter (<PC>)
    └── logos/        downloaded logos
```

Numbers are six-digit, sequential, and resume after the highest existing file when the
server restarts. Several servers (or processes) may share one directory: numbering and the
counter are protected with `flock`. An index line looks like:

```json
{"seq":12,"file":"000012.pdf","time":"2025-10-15T14:30:22-05:00","peer":"172.18.0.5:51234",
 "connection":3,"copy":1,"copies":1,"warnings":["<ZZ>: unknown command ignored"]}
```

(`file` is the `.fgl` and an `"error"` key is present when rendering failed.)

## Configuration

| Flag              | Environment          | Default     | Meaning |
|-------------------|----------------------|-------------|---------|
| `--dpi N`         | `FGL_PDF_DPI`        | `300`       | Printer resolution (dots per inch) |
| `--width-in IN`   | `FGL_PDF_WIDTH_IN`   | `2.0`       | Stock width across the print head |
| `--length-in IN`  | `FGL_PDF_LENGTH_IN`  | `5.5`       | Stock length (feed direction) |
| `--font-dir DIR`  | `FGL_PDF_FONT_DIR`   | —           | Directory with Verdana files for TrueType fonts 3–6 (see [Fonts](#fonts)) |
| `--strict`        | `FGL_PDF_STRICT`     | off         | Raise on unknown/malformed commands instead of warning |
| `--annotate`      | `FGL_PDF_ANNOTATE`   | off         | Add diagnostics (warnings) to the PDF |
| `--debug-grid`    | `FGL_PDF_DEBUG_GRID` | off         | Overlay a dot-coordinate grid |
| `--port N`        | `FGL_PDF_PORT`       | `9100`      | `fgl-printer` listen port |
| `--host ADDR`     | —                    | `0.0.0.0`   | `fgl-printer` bind address |
| `--out DIR`       | `FGL_PDF_OUT`        | (required)  | `fgl-printer` spool directory |
| `--verbose`       | —                    | off         | `fgl-printer` debug logging |

Boolean variables accept `1`, `true`, `yes`, `on`. Flags override the environment.

## Fonts

Boca printers carry TrueType fonts selected with `<RTFn,pt>`; ids 3–6 are commonly the
Verdana family. Verdana can't be redistributed, so the gem ships **DejaVu Sans** (a close,
freely licensed match) and uses it unless you supply Verdana. With DejaVu, text is slightly
wider than on the printer, which matters for centred (`<CTR>`) and right-justified fields.

To render with real Verdana, put your copies in a directory and pass it as `--font-dir DIR`
(both executables), `FGL_PDF_FONT_DIR=DIR`, or `FglPdf::Config.new(font_dir: DIR)`. File
names are matched case-insensitively; any of these spellings works:

| FGL font | Style | Windows | macOS | Linux (msttcorefonts) |
|---|---|---|---|---|
| `<RTF3,pt>` | regular | `verdana.ttf` | `Verdana.ttf` | `Verdana.ttf` |
| `<RTF4,pt>` | bold | `verdanab.ttf` | `Verdana Bold.ttf` | `Verdana_Bold.ttf` |
| `<RTF5,pt>` | italic | `verdanai.ttf` | `Verdana Italic.ttf` | `Verdana_Italic.ttf` |
| `<RTF6,pt>` | bold italic | `verdanaz.ttf` | `Verdana Bold Italic.ttf` | `Verdana_Bold_Italic.ttf` |

Where to find them: `C:\Windows\Fonts` on Windows, `/System/Library/Fonts/Supplemental` on
macOS (pass that directory directly), `/usr/share/fonts/truetype/msttcorefonts` on Linux.
Missing files fall back to DejaVu individually. `fgl-printer` logs the mapping at startup:

```
INFO  TrueType fonts: RTF3=Verdana.ttf RTF4=Verdana Bold.ttf RTF5=Verdana Italic.ttf RTF6=Verdana Bold Italic.ttf
```

In Docker, mount the directory and set the variable. Docker Desktop on macOS can't mount
`/System`, so copy the files somewhere shared first:

```sh
mkdir -p fonts-local && cp /System/Library/Fonts/Supplemental/Verdana*.ttf fonts-local/
docker run --rm -p 9100:9100 -v "$PWD/tickets:/tickets" \
  -v "$PWD/fonts-local:/fonts:ro" -e FGL_PDF_FONT_DIR=/fonts fgl-printer
```

For any other font id or face, map it explicitly in Ruby:
`FglPdf::Config.new(ttf_map: { 7 => '/path/Face.ttf' })`.

The resident bitmap fonts (`<F1>`–`<F13>`) are not replaceable. The OCR fonts (`<F3>`,
`<F6>`, `<F9>` OCR-B; `<F4>`, `<F7>` OCR-A) use the bundled OCR-A and OCR-B fonts, sized to
match a real Boca print: OCR-A capitals fill the glyph height, and OCR-B's glyph height runs
from the top of the digits to the bottom of the descenders, each at its natural width on the
Boca's character pitch. The others are drawn with the standard PDF fonts (Helvetica, Courier,
Times) scaled to each Boca font's glyph size, so positions are exact and letter shapes
approximate.

## Supported FGL

| Area | Commands |
|------|----------|
| Positioning | `<RCrow,col>`, `<SPcol,row>` |
| Rotation | `<NR>` `<RR>` `<RU>` `<RL>` |
| Resident fonts | `<F1>` … `<F13>`, `<HWh,w>` (height/width multipliers), `<SDn>`, `<BSn>` |
| TrueType | `<RTFn,pt>` resident, `<TTFn,pt>` downloaded ids |
| Justification | `<CTRn>` centre and `<RTJn>` right-justify within n dots; `~…~` fields |
| Effects | `<EI>`/`<DI>` inverse, `<OWE>`/`<OWD>` overwrite |
| Lines & boxes | `<BXr,c>`, `<HXn>`, `<VXn>`, `<LTn>` |
| Logos | ESC-delimited downloads, `<IDn>`, `<LDn>`, `<DF…>` |
| Graphics | BMP, PCX, `<G…>` raw bitmaps |
| Counter | `<PC>` print, `<TCn>` set |
| Barcodes | common linear symbologies with human-readable text; QR |
| Placeholders | PDF417, DataMatrix, Aztec (outlined box + label, with a warning) |
| Job control | `<p>` `<q>` `<z>` `<h>` `<r>`, `<REn>` copies, `<CB>`, `<PL>`, FF |

Anything else is ignored with a warning (or raises with `--strict`).

## Fidelity notes

The goal is **faithful output plus warnings**: what we cannot reproduce exactly is drawn as
closely as possible and reported, never silently dropped.

- **Coordinates.** FGL addresses dots on the ticket as printed: `x` is the column along
  the ticket length (feed direction), `y` the row across the head. The PDF page is
  landscape, `length_in × width_in`, so it reads like the physical ticket.
- **Assumptions** where the Boca documentation is ambiguous:
  - TrueType text is anchored at the top of the em box at the current position.
  - A QR module is `pt` dots square (the point-size argument is the module size).
  - A logo downloaded without a preceding `<IDn>` goes to an implicit slot that starts at 1
    when the printer starts and counts up with each such download (like a power cycle).
  - Fractional arguments (e.g. `<RC10,230.0>`) are rounded to whole dots, with a warning.
  - `<LTn><HXlen>` thickness grows *upward* from the row (`row-n … row`), so a rule at the
    bottom row of the stock stays on the ticket; `<VX>` grows rightward, `<BX>` inward.
  - Inline `<G>` graphics follow the current rotation.
  - Resident OCR fonts use bundled OCR-A/OCR-B; the other resident bitmap fonts are
    approximated with Helvetica/Courier/Times scaled to each font's glyph size; TrueType
    ids 3–6 use bundled DejaVu Sans unless Verdana is supplied (see [Fonts](#fonts)).

## License

GPL-3.0-or-later (see `LICENSE`). The bundled DejaVu fonts are under the DejaVu/Bitstream
Vera license (`fonts/DejaVu-LICENSE`). The bundled OCR-A and OCR-B fonts are Matthew Skala's
public-domain versions; their source notices are in `fonts/OCR-LICENSE`.

## Development

```sh
bundle install        # or install the gems from Gemfile system-wide
rspec                 # specs; :integration examples need the full pipeline
rubocop
```

Test fixtures in `spec/fixtures/` are sample jobs: a logo download (a synthetic 1-bit BMP)
and ticket-plus-receipt orders for general admission, reserved seating and a reprint.
