# Ibex, vendored

This directory holds lowRISC's Ibex RISC-V core, used as it is published. It
is the core `rtl/plumbing/cadr_soc.sv` instantiates on the Arty A7-100, where
there is no processing system and a soft processor has to master the register
faces the Zynq's ARM cores master on the other two boards.

**Everything here except `README.md` and `ibex_lint.vlt` is lowRISC's, byte
for byte.** Those two are written here and say so in their own headers. The
licence of everything else is `LICENSE`, which is Apache-2.0; the rest of this
repository is AGPL, and `Digilent-License.txt` in the Arty A7 board directory
is the same arrangement one directory along.

## Where it came from

| | |
|---|---|
| repository | `github.com/lowRISC/ibex` |
| branch | `master` |
| commit | `405c6d1d8220a18b2f9196141167a5875422dee4` |
| commit date | 2026-09-08T11:14:52Z |
| commit subject | [nix] Update nixpkgs and gomod2nix |

**It is pinned by commit and not by a release, because Ibex has no releases.**
The only tags in the repository are eight `pulpino-` and `pulpissimo-` ones
from the project the core was forked out of, the newest of them years old.
OpenTitan vendors Ibex by commit hash for the same reason and this does the
same. The digests below are what makes the pin checkable: a file that changed
under the pin fails `sha256sum -c`.

## What is here and what is not

The file list is Ibex's own `rtl/ibex_core.f`, plus six files that list does
not name and the build needs, plus the include files and the two `prim_` modules
those pull in.

**`ibex_core.f` is out of date upstream and this records which six.**
`ibex_cheriot_pkg.sv` is imported by six of the files the list does name;
`ibex_pmp.sv`, `ibex_csr.sv`, `ibex_dummy_instr.sv`, `ibex_branch_predict.sv`
and `ibex_wb_stage.sv` are instantiated in generate branches this
configuration does not take, and are needed anyway because assertions in
`ibex_core.sv` and `ibex_if_stage.sv` name paths inside them. A module
referenced by an assertion has to exist even when the cell does not.
`ibex_register_file_fpga.sv` is the register file this SoC uses.

**`ibex_top.sv` is NOT here, and that is a decision rather than an omission.**
It is the usual wrapper and it brings the register file, a clock gate and the
instruction cache's RAMs with it. Every one of those is a `prim_` module from
lowRISC's IP library with a technology-specific implementation behind it, and
this board needs none of them: there is no cache, and a clock gate saves power
a board on a bench does not count. So `rtl/plumbing/cadr_soc.sv` instantiates
`ibex_core` bare and `ibex_register_file_fpga` beside it, which is the
smallest composition that runs.

`prim_cipher_pkg.sv` and `prim_lfsr.sv` are here because
`ibex_dummy_instr.sv` instantiates the second, which uses the first. Neither
is reached by this configuration.

The whole of `dv/`, `examples/`, `doc/`, `syn/`, `vendor/` beyond the eight
files below, and the FuseSoC core files are not here. This project builds from
a clone and does not run FuseSoC.

## The configuration

`rtl/plumbing/cadr_soc.sv` sets the parameters and its header gives the
reason for each. In one line: **RV32IMC, two stages, no caches** ---
`BaseIsaRV32I`, `RV32MFast`, `RV32BNone`, `RV32Zca`, `ICache` 0,
`WritebackStage` 0, `PMPEnable` 0, `SecureIbex` 0, `BranchPredictor` 0.

`RV32Zca` and not the default `RV32ZcaZcbZcmp`: Zca is the C extension for an
integer-only target, so that setting is the C of RV32IMC exactly, and Zcb and
Zcmp are decode for instructions `-march=rv32imc` never emits.

## Lint

Ibex does not lint clean at this repository's `-Wall` with warnings fatal.
`ibex_lint.vlt` waives three rules **for this directory only**, by file glob,
and its header says what each is. Ibex's own `lint/verilator_waiver.vlt` is
deliberately not used: its first line turns a rule off globally, with no file
match, which would reach every file in this repository.

## Digests

`sha256sum -c` this list against the directory, or against a fresh clone of the
commit above, and the two agree.

```
cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30  ./LICENSE
06ce1c3ce30807f715478cf9e3bc279cac1c1cc2fb95d289516169fadcf7b7dc  ./rtl/ibex_alu.sv
78d4120eac2606e34b9338581eac55e3ba3b48c718799a46a887ac9efab2240e  ./rtl/ibex_branch_predict.sv
d8b5b51ce99129ebd0c6436689cd85883760ca98f15f45c8a18b977549d007c4  ./rtl/ibex_cheriot_pkg.sv
bea22598e9e5f734ace93826eafd01914d2b63565ee0b7e8c8deff25369fbfbd  ./rtl/ibex_compressed_decoder.sv
bc3211faf87435b07922e3e61646ef83247ab86c5938d4cd2e108802a4357860  ./rtl/ibex_controller.sv
c07ce9c10d04ee6c48263c12e0c2ab1f6666aa44611058c9860ae4f9d5a02c11  ./rtl/ibex_core.f
88b8bf3907472f1d413380f62234a7fbf53cb1de392a6660e6ef2d684a2416fd  ./rtl/ibex_core.sv
0e953e2e05b5070833029d0f6fed6d3a48fbd3c02dc05785962fb0d451425d8e  ./rtl/ibex_counter.sv
898d036f141bdf742c0c772a5493b4bccc9636ffd7c57d3cc37011d233954548  ./rtl/ibex_cs_registers.sv
6533fffc57e233b3961ebd94722a14a1a4320771ce4a76e69481bf2deb1d8514  ./rtl/ibex_csr.sv
842b520e4a942b6a27f3c44f7e8784e4a8dd40d7531a0ec3dd338f624be18217  ./rtl/ibex_decoder.sv
8899ec7fcd6df73d7ea96ad25e73f664ee2ae2a95b2186a36a7ab885e16e292e  ./rtl/ibex_dummy_instr.sv
6451d5cd6af214b5fbb70f7499f898de981188cd7a25bf49247c0819b907c90b  ./rtl/ibex_ex_block.sv
3e0b48b771055ea50356cdff418decae16e7d9586a7f953e6799112b238bb63c  ./rtl/ibex_fetch_fifo.sv
02b40e46ef92df59a9e1d7b80a8d51a366ece0e8e599ca0744fcdf403ccd3aa8  ./rtl/ibex_id_stage.sv
8b99f212f06aa942e53e8a768863587ffdc29176f5a486c6e273262311c9f6ae  ./rtl/ibex_if_stage.sv
86e156efaf7ac46a351a405d9d2046b7d2e6a60bd206411ef9ae474666338b35  ./rtl/ibex_load_store_unit.sv
c86ca819b58b8ce2fc4ff5db887346bcd622b868fb7815fa07dd77119c68c04a  ./rtl/ibex_multdiv_fast.sv
88b7392d3e2cd1f67f2c39b7425075030c78646cba2409356d6cfce262a46db6  ./rtl/ibex_multdiv_slow.sv
d9bfed30b16dd77981f1850a8daf56fec5ce14043789b4a0a4506c833e9a7d5a  ./rtl/ibex_pkg.sv
a564fb312d5337b0875d16f434e8b69348e12c2560548fad93f9270f9c4b9176  ./rtl/ibex_pmp.sv
988ca05039f033c0eef9feffba996771c3449f255c64d7d78de04e1984249ccc  ./rtl/ibex_prefetch_buffer.sv
cb758da72120fa1ab7c3837408ef10ab96375edf727f6400d606ff5850e68a93  ./rtl/ibex_register_file_ff.sv
ae98b043c2fec8ae44784157d559673518b1febda4eb7d5862ef07094b6cf3fc  ./rtl/ibex_register_file_fpga.sv
872d8df3b3f3fd9ba781eabd3897bd3b74d2b3af2d2898ab5799371d05b04e8a  ./rtl/ibex_wb_stage.sv
d8d02ae47a12d78f611e15e4ab6e14775b55a0bdbb0815f36fbe8ddb242984ae  ./vendor/lowrisc_ip/dv/sv/dv_utils/dv_fcov_macros.svh
cac4a930105da662547de873f0b80246074fb22df9a398663e1c8ac3e7998218  ./vendor/lowrisc_ip/ip/prim/rtl/prim_assert_dummy_macros.svh
25db89fe5f250c1bcbd808d0b4808206b9e85ac337b26e4ebb23f2ad569e1a13  ./vendor/lowrisc_ip/ip/prim/rtl/prim_assert_sec_cm.svh
4835706249e017eae999256ea807c526a39a49729196fc0aa18bb8818de86ab6  ./vendor/lowrisc_ip/ip/prim/rtl/prim_assert_standard_macros.svh
d717d5dbcba3b5aa8a731ef9f8af18b036b49edef282f0a43a51f5ad2dd9bb40  ./vendor/lowrisc_ip/ip/prim/rtl/prim_assert.sv
d1fd8c350785a7c6d8cccc0b0c385392b71575397e7dc58c70f07716c8f9f3a3  ./vendor/lowrisc_ip/ip/prim/rtl/prim_assert_yosys_macros.svh
9cd66bdbc64020e3fe1f14a5baee30a93609b7887a9d21df7991929087b0973f  ./vendor/lowrisc_ip/ip/prim/rtl/prim_cipher_pkg.sv
2e8e6c2ee484899ae5d0020eaf0c9732c31537c60c30cb2a0a0acd2e92baee03  ./vendor/lowrisc_ip/ip/prim/rtl/prim_flop_macros.sv
c61632878728613ba0403f2d068c03a5103165663b58d8dd50892ef032dec916  ./vendor/lowrisc_ip/ip/prim/rtl/prim_lfsr.sv
```
