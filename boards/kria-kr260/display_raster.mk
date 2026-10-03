# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Kria KR260's raster, CEA-861's 1920x1080 at 60 Hz, as the display
# check builds `rtl/plumbing/cadr_display_out.sv` with it
# (`build/display_out_kr260.pass`).  `tools/machine_param_check.py` holds
# that `boards/kria-kr260/cadr_kr260.sv` hands its `u_display` these same
# figures, and `cadr-displayport` writes them into the DisplayPort
# controller's main stream attributes.
DISPLAY_KR260_G := -GH_ACTIVE=1920 -GH_FRONT=88 -GH_SYNC=44 -GH_BACK=148 \
                   -GV_ACTIVE=1080 -GV_FRONT=4 -GV_SYNC=5 -GV_BACK=36
