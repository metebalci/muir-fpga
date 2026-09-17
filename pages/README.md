# `pages/`

This directory is the project page. The files are hand-written, and there is no
build step and no generator, the same way
[muir's `site/`](https://github.com/metebalci/muir/tree/main/site) has none.
The pages are drawn in the hand of Cold Boot, a manga-style zine about the
CADR: ink and one spot color, fluorescent pink, on paper, in panels with a
who-line ruled off under each section. muir's and ozd's sites are drawn in the
same hand, and this one takes muir's stylesheet so that the three are one
family.

**The pages are brief, and the documents are long.** A page is its drawings,
its tables and a few sentences around them. Anything longer lives in `docs/`
in the repository, and the page links to the file. The page's own text is
there so a reader can tell what the drawing is before they read it, and not to
say again what a document already says.

    index.html    the front page. What the project is, in two speech bubbles
                  and a terminal block, then one table with a row for each
                  board, the board's name linking its own page, and under it
                  the FPGA's product name, its part number and a link to the
                  maker's page for the board. A board with no page here yet
                  has a row of its name, linked to its maker's page, its part,
                  and the word upcoming, and nothing else. It ends with
                  the license and a table of the third-party material the
                  boards and the site use, each row naming whose it is, under
                  what terms, and where those terms are recorded. The long
                  form of that table is docs/license.md. The tables' styles
                  are in front.css beside it, because the tables are this
                  project's own rather than muir's
    arty-z7-20.html
                  the Arty Z7-20's architecture drawing, under the board's
                  name, one line naming the FPGA it runs on, one line linking
                  the maker's page for the board, and the keys to the pages
                  that explain it. How it boots is on booting.html with the
                  other board's
    cora-z7-07s.html
                  the same drawing for the Cora Z7-07S. That board has no
                  HDMI connector, no USB host port and no switches, so the
                  display output block, its port, the
                  HDMI connector, the USB input program, the USB host
                  controller, the port it would drive and the no-auto-boot
                  switch are crossed off in their places
    booting.html  how each board comes up, in two sequences: a Zynq board
                  from its own card, and the same board from a TFTP server
                  while it is being worked on. The two Zynq boards come up the
                  same way, so one drawing serves both and a label says where
                  they differ. The long form is docs/boot.md
    debugging.html
                  how one CADR debugs another, in five drawings: MIT's cable
                  of twenty-one wires and what CC reaches over it, the two
                  ways into a board's own debuggee end, the ribbon between two
                  Pmod headers, and the frame the pins carry. It ends with a
                  table of what has run on a board and what has not. The long
                  form is docs/debug-cable.md
    faq.html      questions this project is asked, each with an answer of a
                  sentence or two and a line naming the file it rests on. The
                  whole of each answer is in docs/faq.md. The first is why
                  there is no disk multiplexor block. There are no drawings on
                  it. Its styles are in faq.css beside it
    cadr.html     the real CADR in ten drawings with one-sentence captions:
                  the machine, its boards, cables and buses, and how it boots.
                  What each drawing shows, and every source it was read from,
                  is in docs/cadr.md
    full-page.html
                  a fuller draft kept for later: the architecture drawing with
                  its caption, the target and its block-RAM budget, the
                  fabric/Linux split, a second drawing of the Xbus address
                  space, and where things stand. Deliberately not committed
                  --- it is in .gitignore with a TEMPORARY marker --- and it
                  is here to be drawn from rather than published as it stands
    style.css     muir's stylesheet, with the drawings' classes added --- see
                  below
    fonts/        Dela Gothic One, Zen Maru Gothic and IBM Plex Mono, so a
                  visitor does not have to ask a third party for the page to
                  be readable
    .nojekyll     keeps GitHub Pages from running Jekyll over it

## The shape of a page

Every page is the same shape. A desk note at the top, as on muir's and ozd's
sites, gives the project's name and then all seven pages, in one fixed order on
every page, so no word on it moves as a reader goes from page to page. The page
being read is plain text on the spot color, marked `aria-current`, and every
other page is a link. After the boards that have a page, a board with no page
here yet is named, linked to its maker's page, with the word upcoming beside
it. Under it the page is a column of paper plates on a
halftone desk. Each plate opens with a pink eyebrow and a title in the display
face, holds its panels, and closes with a who-line whose last cell is the
plate's number on its page. The last plate of every page is the colophon: the
copyright, where the drawing style and the board come from, and the board
waving goodbye. The front page's colophon is shaped as muir's is: where the
material comes from, how the project is made, the name, the license, and the
credits.

**A board page** is `arty-z7-20.html` or `cora-z7-07s.html`. It is one plate:
the board's name, one line naming the FPGA by its product name and part, one
line linking the maker's page for the board, the keys to the booting and
debugging pages and to the other board, and the drawing in a panel of its own.
The keys all look alike. The drawing carries its own legend, and nothing
outside the drawing explains it. No outline is drawn around the board: the
chip's own outline is the one labeled, with the FPGA's product name beside its
part number, and the memory, the connectors, the lamps, the buttons and the
Pmod header stand outside it. The legend is one row under the drawing,
centered on it, with every swatch and word on one baseline, spaced by each
word's measured width. Anything that
does belongs in `full-page.html` or in `docs/`.

**A page with prose** is `index.html`, `booting.html`, `debugging.html`,
`faq.html` or `cadr.html`. What text it has is written in brief full
sentences, because it is read by people who did not write the code, and every
long form it points at is a Markdown file in `docs/`.

`booting.html`, `debugging.html` and `cadr.html` carry drawings, and all three
of them draw in `currentColor` alone. **A sequence carries no status color.**
A board drawing colors a block by how far along it is; a sequence says what
happens and in what order, which is a different claim, so what is built and
what is not is in the caption under each figure, in words.

## The characters

The characters are inline SVG, defined once at the top of each page that uses
them and placed with `<use>`. They are drawn in `#141414` and `#fff` with the
spot pink, and they are pictures rather than drawings of the machine, so they
make no claim about it.

**The board is the site's mascot.** It was drawn for this site by the
[ozd](https://github.com/metebalci/ozd) project, in Cold Boot's hand, and it
is copied here unchanged from ozd's `pages/index.html`, where it was added at
ozd commit `b707ecc`. Its chip wears CADR's face. The DDR3 beside it, the
Ethernet jack and the microSD slot are the Arty Z7-20's, and the mounting
holes and the lights are any development board's. ozd is under the AGPL,
version 3 or later.

**CADR's body, its face and its waving arm are Cold Boot's own parts**, under
CC BY-SA 4.0, and the board wears the face and the arm. The two boards joined
by a ribbon on the debugging page are the mascot twice, with the ribbon drawn
between them in the same hand.

## The drawings

The drawings are inline SVG and use the `d-*` classes the stylesheet defines.
They are hand-placed rather than generated, because nothing here reads the RTL.
So **a change to the architecture is a change to the drawing**, made by hand,
and the drawing can drift from the machine.

There are two architecture drawings, one per board. The Arty Z7-20's is
the original, and the other is derived from it. It shares its viewBox and
its translation, and a block the two boards both have is at the same coordinates in
both.

**The derived one is derived by crossing off.** The Cora Z7-07S is the same
architecture on the Zynq 7007S. Its drawing is the Arty Z7-20's with what that
board does not have crossed off where it stands rather than taken out, so that
a reader can see what is missing.

**Every controller in the row at the foot of a drawing has the same left edge
and the same width as the connector under it.** A controller and the thing it
drives therefore read as one column, and the gaps in the row are what the
connectors leave between them. Two lines pay for that: the port from the
software region into the memory controller lands on its top edge rather than
on its right, which the wider box would swallow; and the UART's own line comes
down on the UART's right, the gap on its left being the SD host's now.

Under the machine, each drawing is three layers. The software region is on
top. That is the Linux programs the board runs. Beside that region, at its
left, stand the processor it runs on and the boot that starts that processor,
in the same two places on both drawings: the Arm cores and U-Boot. Under it is
a row of controllers, one for each
thing the board is attached to: the memory controller, the MAC, the SD host,
the UART, and on the Arty Z7-20 the USB host. Under that row are the board's own
connectors, one under each controller. A line that leaves a program ends on a
controller and never on a connector. Each controller has one line down to the
connector it drives. On both boards every controller in the row is the part's
own silicon, so the whole row is gray.

So a change to a block the Arty Z7-20 shares with the other board is carried
to that board's drawing by the same edit, at the same coordinates, and the two
can be compared with `diff`. The
differences that are meant to be there are the chip's label, the figures
under the fabric's label, the status colors and the lamp rows, and then
whatever the derivation itself adds. On the Cora Z7-07S that is the crossed-off
blocks and the legend's extra swatch, which also moves the legend's other
swatches, because the row is centered. Anything else in a diff between these two
files is a drift, and that is the point of keeping the geometry identical.

Everything the drawings assert about the machine comes from `README.md`,
`rtl/machine/cadr_cables.map` and `rtl/machine/cadr_xbus_decode.sv`. The fit
and timing figures under each fabric label come from that board's own place and
route report at the commit its comment names.

A block's color says how far along it is, and the legend on each drawing
carries the words. Green means the board itself has shown it. Turquoise means
it is built and checked here and has not run on that board. The boards differ:
a block that is green on one may be turquoise on another, because the claim is
about a board and not about the code.

A block with no color at all has not been started. It is drawn so that the
shape of the machine is known before the work begins. The Color TV --- MIT's
second display board, on the Xbus beside the monochrome one on both
pages --- was drawn that way for a while and is turquoise now: it is built and
checked here, and no monitor has shown its picture.

On a drawing derived by crossing off, a block that board does not have carries
no color at all. It keeps its place, goes dashed, and takes a red cross corner
to corner with its label left faint. That is the one mark on these drawings
that says nothing about progress, and the legend calls it "not available on
this board". A line that exists only to reach such a block stays drawn and goes
faint with it, as far as the first junction where another line joins it or the
first box it meets, because past that junction the same wire serves something
the board does have.

## What `style.css` adds to muir's

The chrome is muir's stylesheet as it is: its tokens, its panels, its speech
bubbles, its keys, its contents, its tables and its who-line. What is added is
this site's own.

**Font sizes are in rem, and the base is set once, on `body`.** Nothing styles
`html`. Pinning the root would silently override a reader who has raised their
browser's default, and that is the one accessibility choice that matters. The
wordmark's `clamp()` keeps a rem term in its middle value for the same reason.
The one exception is the drawings: the `d-*` rules give their sizes in the
drawing's own viewBox units, which scale with the picture.

**There is no dark mode**, as there is none on muir's or ozd's. Paper and ink
is what this is, and a spot color printed on black is a different object. The
status colors on the drawings are therefore chosen, and checked, on paper
alone.

`.desk-note` is muir's, with the pages added to it as one fixed line, and
`body.wide` lets a board page's plate out to hold the drawing at about its own
size.

`.fig.dense` is for the booting page's sequences, which carry more label text
than muir's figures, so they scroll sooner rather than shrinking below
legibility. `.fig.dense.wide` is for the architecture drawings, which scale
with their plate and never force a scrollbar, except on a phone, where they
keep a readable width and scroll inside their own panel.

The drawings' labels are set in the voice, Zen Maru Gothic, as muir's are.
Measured in a browser against the face they were placed with, every label is
two to seven per cent narrower, and none runs past its box.

`.d-warn` is added for the one red label on the drawings. The debug cable's
supply pins are open at both ends, because a cable between two boards must not
join their 3.3 V rails, and the connector's own block says so. It takes the
crossings' red rather than a color of its own, so that red on a drawing goes on
meaning one thing.

`faq.css` is one rule, for the line under each answer that names the file
the answer rests on. It is kept beside its page for the reason the two files
below are: one page wanting one small thing is not a reason to put it in the
stylesheet every page loads. **Every answer on that page carries such a
line**, and a question whose answer rests on nothing tracked does not go on
the page.

`debugging.css` is the same arrangement as `cadr.css`: what that page's
drawings need beyond the shared classes, kept beside it so that the cable page
and the page on the real machine can be changed one at a time. Three of its
four rules are `cadr.css`'s repeated, on purpose, because two pages wanting the
same small thing is not a reason to put it in the stylesheet every page loads.
The fourth is `.d-x.d-warn`, which is there because a `font:` shorthand read
after `style.css` would otherwise take the red out of the smallest label.

`.d-absent`, `.d-absent-x`, `.d-absent-t`, `.d-absent-l` and `.d-absent-key`
are added for a block a board does not have and for the wires that reach it.
The outline, the faint label and the faded line use the drawing's own ink
through `currentColor`. Only the cross has a color of its own, `--st-absent`,
which is the red the error lamp is already drawn in.

## Looking at it

    python3 -m http.server -d pages 8000

You can also open `index.html` directly. There is no build.

## Publishing

`.github/workflows/pages.yml` uploads this directory to GitHub Pages on every
push that touches it. Nothing is built. The directory goes up as it stands,
which is what `.nojekyll` is for. The one repository setting it needs, Pages ->
Build and deployment -> Source: **GitHub Actions**, is already done.

It lands at <https://metebalci.github.io/muir-fpga/>. A custom domain, if one
is ever wanted, is a `CNAME` record plus the Custom domain field.
`muir.metebalci.com` is set up that way.

One thing to know about what that publishes: **everything committed under
`pages/` becomes reachable**, whether it is linked or not. That is why
`full-page.html` is gitignored rather than merely unlinked. It would otherwise
answer at `/full-page.html` with nothing pointing at it.
