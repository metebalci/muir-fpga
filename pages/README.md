# `pages/`

This directory is the project page. The files are hand-written, and there is no
build step and no generator, the same way
[muir's `site/`](https://github.com/metebalci/muir/tree/main/site) has none:

    index.html    the front page. What the project is in a paragraph, then one
                  table with a row for each board saying what that board is and
                  what it does, each board's name linking its own page, and a
                  link to the page on the real machine. The table's styles are
                  in front.css beside it, because the table is this project's
                  own rather than muir's. It ends with the project's license
                  and a list of the third-party material the boards use, each
                  entry naming whose it is and under what terms
    arty-z7-20.html
                  the Arty Z7-20's architecture drawing, and nothing else. How
                  it boots is on booting.html with the other two boards'
    cora-z7-07s.html
                  the same drawing for the Cora Z7-07S. That part is
                  smaller and the board has no HDMI connector, no USB host port
                  and no switches, so the display output block, its port, the
                  HDMI connector, the USB input program, the USB host
                  controller, the port it would drive and the no-auto-boot
                  switch are crossed off in their places
    arty-a7-100.html
                  the architecture drawing for the Arty A7-100. That board has
                  no processing system at all, so everything the Arm cores and
                  Linux do on the other two has to have an answer in fabric,
                  and the drawing shows those answers in the positions the
                  processing system's own parts hold. It draws nothing the
                  board has not got, and nothing on it is crossed off
    booting.html  how each board comes up, in three sequences: a Zynq board
                  from its own card, the same board from a TFTP server while
                  it is being worked on, and the Arty A7-100 from its own
                  flash. The two Zynq boards come up the same way, so one
                  drawing serves both and a label says where they differ. The
                  Arty A7-100's is a plan and its caption says so
    debugging.html
                  how one CADR debugs another, in five drawings: MIT's cable
                  of twenty-one wires and what CC reaches over it, the two
                  ways into a board's own debuggee end, the ribbon between two
                  Pmod headers, and the frame the eight pins carry. It ends
                  with a table of what has run on a board and what has not
    faq.html      questions this project is asked, each with an answer of a
                  few sentences and a line naming the file it rests on. The
                  first is why there is no disk multiplexor block. There are
                  no drawings on it. Its styles are in faq.css beside it
    cadr.html     the real CADR in ten drawings with one-sentence captions:
                  the machine, its boards, cables and buses, and how it boots
                  document named at the end of the page
    full-page.html
                  a fuller draft kept for later: the architecture drawing with
                  its caption, the target and its block-RAM budget, the
                  fabric/Linux split, a second drawing of the Xbus address
                  space, and where things stand. Deliberately not committed
                  --- it is in .gitignore with a TEMPORARY marker --- and it
                  is here to be drawn from rather than published as it stands
    style.css     muir's stylesheet, with one change --- see below
    fonts/        Archivo and IBM Plex Mono, so a visitor does not have to
                  ask a third party for the page to be readable
    .nojekyll     keeps GitHub Pages from running Jekyll over it

## The two kinds of page

A **drawing page** is `arty-z7-20.html`, `cora-z7-07s.html` or
`arty-a7-100.html`. The drawing is
the page. There is no heading, no caption and no prose on it, and each drawing
carries its own title inside it. The only text outside the drawings is one
faint line at the top saying which board this is and linking the other pages.
Anything that explains a drawing belongs in `full-page.html` or in `docs/`,
not here.

A **prose page** is `index.html`, `booting.html`, `debugging.html`,
`faq.html` or `cadr.html`. Those carry the topbar, and they are written in
brief full sentences because they are read by people who did not write the
code.

`booting.html`, `debugging.html` and `cadr.html` are prose pages that carry
drawings, and all three of them draw in `currentColor` alone. **A sequence
carries no status color.**
A board drawing colors a block by how far along it is; a sequence says what
happens and in what order, which is a different claim, so what is built and
what is not is in the caption under each figure, in words. The Arty A7-100's
sequence is a plan rather than a board, and its caption is where that is
said.

## The drawings

The drawings are inline SVG and use the `d-*` classes the stylesheet defines.
They are hand-placed rather than generated, because nothing here reads the RTL.
So **a change to the architecture is a change to the drawing**, made by hand,
and the drawing can drift from the machine.

There are now three architecture drawings, one per board. The Arty Z7-20's is
the original, and the other two are derived from it. They share its viewBox and
its translation, and a block two boards both have is at the same coordinates in
both.

**The two are derived in two different ways, because the two boards differ from
the original in two different ways.** The Cora Z7-07S is the same architecture
on a smaller part. Its drawing is the Arty Z7-20's with what that board does
not have crossed off where it stands rather than taken out, so that a reader
can see what is missing. The Arty A7-100 has no processing system at all, which
makes it a different architecture around the same CADR rather than a smaller
version of the same one. Its drawing therefore shows what is on that board and
nothing else. Nothing on it is crossed off, what the board has not got is not
drawn, and its legend has no row for the mark. What takes the place of the
processing system is drawn in the positions that system's own parts hold, and
that is what keeps the two pages readable side by side.

**Every controller in the row at the foot of a drawing has the same left edge
and the same width as the connector under it.** A controller and the thing it
drives therefore read as one column, and the gaps in the row are what the
connectors leave between them. Two lines pay for that: the port from the
software region into the memory controller lands on its top edge rather than
on its right, which the wider box would swallow; and the UART's own line comes
down on the UART's right, the gap on its left being the SD host's now.

Under the machine, each drawing is three layers. The software region is on
top. That is the Linux programs on a Zynq board and the firmware's own services
on the Arty A7-100. Beside that region, at its left, stand the processor it
runs on and the boot that starts that processor, in the same two places on all
three drawings: the Arm cores and U-Boot on the Zynq boards, the Ibex and the
QSPI flash on the Arty A7-100. Under it is a row of controllers, one for each
thing the board is attached to: the memory controller, the MAC, the SD host,
the UART, and on the Arty Z7-20 the USB host. Under that row are the board's own
connectors, one under each controller. A line that leaves a program ends on a
controller and never on a connector. Each controller has one line down to the
connector it drives. On the two Zynq boards every controller in the row is the
part's own silicon, so the whole row is gray. On the Arty A7-100 every one of
them is in the fabric, so each carries a color of its own.

So a change to a block the Arty Z7-20 shares with another board is carried to
that board's drawing by the same edit, at the same coordinates, and the three
can be compared with `diff`. The
differences that are meant to be there are the titles, the part, the figures
under the fabric's label, the status colors and the lamp rows, and then
whatever the derivation itself adds. On the Cora Z7-07S that is the crossed-off
blocks and the legend's extra swatch. On the Arty A7-100 it is the blocks that
replace the processing system's, the blocks that are not drawn at all, and the
legend one row shorter. Anything else in a diff between two of these files is
a drift, and that is the point of keeping the geometry identical.

The Arty A7-100's largest difference is the band under the machine. The other
two drawings have a row of five port boxes there, and each of those is a hard
boundary: the place the fabric's wires stop and the processing system's silicon
begins. The Arty A7-100 has no such boundary anywhere, so that band holds one
box and two wires and is otherwise empty. The box is the soft system's AXI
bridge, which is a component. The two wires are the machine's memory path and
the disk controller's channel, each running as one line from the block that
masters it into the memory controller at the foot of the drawing. Nothing is
drawn where they pass, because naming a wire in a box would invent a part the
board has not got.

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
second display board, on the Xbus beside the monochrome one on all three
pages --- was drawn that way for a while and is turquoise now: it is built and
checked here, and no monitor has shown its picture.

On a drawing derived by crossing off, a block that board does not have carries
no color at all. It keeps its place, goes dashed, and takes a red cross corner
to corner with its label left faint. That is the one mark on these drawings
that says nothing about progress, and the legend calls it "not available on
this board". A line that exists only to reach such a block stays drawn and goes
faint with it, as far as the first junction where another line joins it or the
first box it meets, because past that junction the same wire serves something
the board does have. The Arty A7-100's drawing uses none of this. It is not the
original with pieces struck out, so it draws only what is there.

## The one change to muir's stylesheet

muir sets `html { font-size: 17px }` and states its type scale as fractions of
that. This copy leaves the root alone and sets the base on `body` instead, with
the scale restated against a 16px root. Pinning the root silently overrides a
reader who has raised their browser's default, and that is the one
accessibility choice that matters. The rendered sizes are identical at a
default root, and they follow the reader when it is not the default. muir took
the narrow-screen step from 17px to 16 in one line. That is still one line
here, as a block of token overrides under `@media (max-width: 720px)`.

`.fig.dense` is added for the architecture drawings. Those drawings carry more
label text than muir's figures, so they scroll sooner rather than shrinking
below legibility. `.crumb` is added for the faint line on the drawing pages.

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
through `currentColor`, so they follow the reader's theme like everything else.
Only the cross has a color of its own, `--st-absent`, which is the red the
error lamp is already drawn in.

## Looking at it

    python3 -m http.server -d site 8000

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
