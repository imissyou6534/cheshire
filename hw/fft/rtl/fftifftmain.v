////////////////////////////////////////////////////////////////////////////////
//
// Filename:	fftifftmain.v
// {{{
// Project:	A General Purpose Pipelined FFT Implementation
//
// Purpose:	This is the main module in the General Purpose FPGA FFT
//		implementation.  As such, all other modules are subordinate
//	to this one.  This module accomplish a fixed size Complex FFT on
//	4096 data points.
//	The FFT is fully pipelined, and accepts as inputs two complex two's
//	complement samples per clock.
//
// Parameters:
//	i_clk	The clock.  All operations are synchronous with this clock.
//	i_reset	Synchronous reset, active high.  Setting this line will
//			force the reset of all of the internals to this routine.
//			Further, following a reset, the o_sync line will go
//			high the same time the first output sample is valid.
//	i_ce	A clock enable line.  If this line is set, this module
//			will accept two complex values as inputs, and produce
//			two (possibly empty) complex values as outputs.
//	i_left	The first of two complex input samples.  This value is split
//			into two two's complement numbers, 16 bits each, with
//			the real portion in the high order bits, and the
//			imaginary portion taking the bottom 16 bits.
//	i_right	This is the same thing as i_left, only this is the second of
//			two such samples.  Hence, i_left would contain input
//			sample zero, i_right would contain sample one.  On the
//			next clock i_left would contain input sample two,
//			i_right number three and so forth.
//	o_left	The first of two output samples, of the same format as i_left,
//			only having 23 bits for each of the real and imaginary
//			components, leading to 46 bits total.
//	o_right	The second of two output samples produced each clock.  This has
//			the same format as o_left.
//	o_sync	A one bit output indicating the first valid sample produced by
//			this FFT following a reset.  Ever after, this will
//			indicate the first sample of an FFT frame.
//
// Arguments:	This file was computer generated using the following command
//		line:
//
//		% ./fftgen -U -2 -f 4096 -n 16 -p 0 -d /tmp/cheshire-dual-runtime-20261019
//
//	This core will use hardware accelerated multiplies (DSPs)
//	for 0 of the 12 stages
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
// }}}
// Copyright (C) 2015-2024, Gisselquist Technology, LLC
// {{{
// This file is part of the general purpose pipelined FFT project.
//
// The pipelined FFT project is free software (firmware): you can redistribute
// it and/or modify it under the terms of the GNU Lesser General Public License
// as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// The pipelined FFT project is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTIBILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser
// General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License
// along with this program.  (It's in the $(ROOT)/doc directory.  Run make
// with no target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
// }}}
// License:	LGPL, v3, as defined and found on www.gnu.org,
// {{{
//		http://www.gnu.org/licenses/lgpl.html
//
// }}}
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
//
//
`ifndef CHESHIRE_FFT_COEFF_ROOT
`define CHESHIRE_FFT_COEFF_ROOT "../../../hw/fft/rtl"
`endif
// Keep i_inverse stable through the task, and reset before changing direction.
module fftifftmain(i_clk, i_reset, i_ce,
		i_inverse, i_left, i_right,
		o_left, o_right, o_sync);
	// The bit-width of the input, IWIDTH, output, OWIDTH, and the log
	// of the FFT size.  These are localparams, rather than parameters,
	// because once the core has been generated, they can no longer be
	// changed.  (These values can be adjusted by running the core
	// generator again.)  The reason is simply that these values have
	// been hardwired into the core at several places.
	localparam	IWIDTH=16, OWIDTH=23; // LGWIDTH=12;
	//
	input	wire				i_clk, i_reset, i_ce;
	//
	input	wire				i_inverse;
	input	wire	[(2*IWIDTH-1):0]	i_left, i_right;
	output	reg	[(2*OWIDTH-1):0]	o_left, o_right;
	output	reg				o_sync;


	// Outputs of the FFT, ready for bit reversal.
	wire				br_sync;
	wire	[(2*OWIDTH-1):0]	br_left, br_right;


	wire		w_s4096;
	// verilator lint_off UNUSED
	wire		w_os4096;
	// verilator lint_on  UNUSED
	wire	[33:0]	w_e4096, w_o4096;
	fftstage	#(
		// {{{
		.IWIDTH(IWIDTH),
		.CWIDTH(IWIDTH+4),
		.OWIDTH(17),
		.LGSPAN(10),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_e8192.hex"})
		// }}}
	) stage_e4096(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(!i_reset),
		.i_data(i_left),
		.o_data(w_e4096),
		.o_sync(w_s4096)
		// }}}
	);
	fftstage	#(
		// {{{
		.IWIDTH(IWIDTH),
		.CWIDTH(IWIDTH+4),
		.OWIDTH(17),
		.LGSPAN(10),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_o8192.hex"})
		// }}}
	) stage_o4096(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(!i_reset),
		.i_data(i_right),
		.o_data(w_o4096),
		.o_sync(w_os4096)
		// }}}
	);


	wire		w_s2048;
	// verilator lint_off UNUSED
	wire		w_os2048;
	// verilator lint_on  UNUSED
	wire	[35:0]	w_e2048, w_o2048;
	fftstage	#(
		// {{{
		.IWIDTH(17),
		.CWIDTH(21),
		.OWIDTH(18),
		.LGSPAN(9),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_e4096.hex"})
		// }}}
	) stage_e2048(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s4096),
		.i_data(w_e4096),
		.o_data(w_e2048),
		.o_sync(w_s2048)
		// }}}
	);
	fftstage	#(
		// {{{
		.IWIDTH(17),
		.CWIDTH(21),
		.OWIDTH(18),
		.LGSPAN(9),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_o4096.hex"})
		// }}}

) 	stage_o2048(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s4096),
		.i_data(w_o4096),
		.o_data(w_o2048),
		.o_sync(w_os2048)
		// }}}
	);

	wire		w_s1024;
	// verilator lint_off UNUSED
	wire		w_os1024;
	// verilator lint_on  UNUSED
	wire	[35:0]	w_e1024, w_o1024;
	fftstage	#(
		// {{{
		.IWIDTH(18),
		.CWIDTH(22),
		.OWIDTH(18),
		.LGSPAN(8),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_e2048.hex"})
		// }}}
	) stage_e1024(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s2048),
		.i_data(w_e2048),
		.o_data(w_e1024),
		.o_sync(w_s1024)
		// }}}
	);
	fftstage	#(
		// {{{
		.IWIDTH(18),
		.CWIDTH(22),
		.OWIDTH(18),
		.LGSPAN(8),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_o2048.hex"})
		// }}}

) 	stage_o1024(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s2048),
		.i_data(w_o2048),
		.o_data(w_o1024),
		.o_sync(w_os1024)
		// }}}
	);

	wire		w_s512;
	// verilator lint_off UNUSED
	wire		w_os512;
	// verilator lint_on  UNUSED
	wire	[37:0]	w_e512, w_o512;
	fftstage	#(
		// {{{
		.IWIDTH(18),
		.CWIDTH(22),
		.OWIDTH(19),
		.LGSPAN(7),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_e1024.hex"})
		// }}}
	) stage_e512(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s1024),
		.i_data(w_e1024),
		.o_data(w_e512),
		.o_sync(w_s512)
		// }}}
	);
	fftstage	#(
		// {{{
		.IWIDTH(18),
		.CWIDTH(22),
		.OWIDTH(19),
		.LGSPAN(7),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_o1024.hex"})
		// }}}

) 	stage_o512(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s1024),
		.i_data(w_o1024),
		.o_data(w_o512),
		.o_sync(w_os512)
		// }}}
	);

	wire		w_s256;
	// verilator lint_off UNUSED
	wire		w_os256;
	// verilator lint_on  UNUSED
	wire	[37:0]	w_e256, w_o256;
	fftstage	#(
		// {{{
		.IWIDTH(19),
		.CWIDTH(23),
		.OWIDTH(19),
		.LGSPAN(6),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
			.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_e512.hex"})
		// }}}
	) stage_e256(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s512),
		.i_data(w_e512),
		.o_data(w_e256),
		.o_sync(w_s256)
		// }}}
	);
	fftstage	#(
		// {{{
		.IWIDTH(19),
		.CWIDTH(23),
		.OWIDTH(19),
		.LGSPAN(6),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_o512.hex"})
		// }}}

) 	stage_o256(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s512),
		.i_data(w_o512),
		.o_data(w_o256),
		.o_sync(w_os256)
		// }}}
	);

	wire		w_s128;
	// verilator lint_off UNUSED
	wire		w_os128;
	// verilator lint_on  UNUSED
	wire	[39:0]	w_e128, w_o128;
	fftstage	#(
		// {{{
		.IWIDTH(19),
		.CWIDTH(23),
		.OWIDTH(20),
		.LGSPAN(5),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_e256.hex"})
		// }}}
	) stage_e128(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s256),
		.i_data(w_e256),
		.o_data(w_e128),
		.o_sync(w_s128)
		// }}}
	);
	fftstage	#(
		// {{{
		.IWIDTH(19),
		.CWIDTH(23),
		.OWIDTH(20),
		.LGSPAN(5),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_o256.hex"})
		// }}}

) 	stage_o128(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s256),
		.i_data(w_o256),
		.o_data(w_o128),
		.o_sync(w_os128)
		// }}}
	);

	wire		w_s64;
	// verilator lint_off UNUSED
	wire		w_os64;
	// verilator lint_on  UNUSED
	wire	[39:0]	w_e64, w_o64;
	fftstage	#(
		// {{{
		.IWIDTH(20),
		.CWIDTH(24),
		.OWIDTH(20),
		.LGSPAN(4),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_e128.hex"})
		// }}}
	) stage_e64(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s128),
		.i_data(w_e128),
		.o_data(w_e64),
		.o_sync(w_s64)
		// }}}
	);
	fftstage	#(
		// {{{
		.IWIDTH(20),
		.CWIDTH(24),
		.OWIDTH(20),
		.LGSPAN(4),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_o128.hex"})
		// }}}

) 	stage_o64(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s128),
		.i_data(w_o128),
		.o_data(w_o64),
		.o_sync(w_os64)
		// }}}
	);

	wire		w_s32;
	// verilator lint_off UNUSED
	wire		w_os32;
	// verilator lint_on  UNUSED
	wire	[41:0]	w_e32, w_o32;
	fftstage	#(
		// {{{
		.IWIDTH(20),
		.CWIDTH(24),
		.OWIDTH(21),
		.LGSPAN(3),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_e64.hex"})
		// }}}
	) stage_e32(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s64),
		.i_data(w_e64),
		.o_data(w_e32),
		.o_sync(w_s32)
		// }}}
	);
	fftstage	#(
		// {{{
		.IWIDTH(20),
		.CWIDTH(24),
		.OWIDTH(21),
		.LGSPAN(3),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_o64.hex"})
		// }}}

) 	stage_o32(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s64),
		.i_data(w_o64),
		.o_data(w_o32),
		.o_sync(w_os32)
		// }}}
	);

	wire		w_s16;
	// verilator lint_off UNUSED
	wire		w_os16;
	// verilator lint_on  UNUSED
	wire	[41:0]	w_e16, w_o16;
	fftstage	#(
		// {{{
		.IWIDTH(21),
		.CWIDTH(25),
		.OWIDTH(21),
		.LGSPAN(2),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_e32.hex"})
		// }}}
	) stage_e16(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s32),
		.i_data(w_e32),
		.o_data(w_e16),
		.o_sync(w_s16)
		// }}}
	);
	fftstage	#(
		// {{{
		.IWIDTH(21),
		.CWIDTH(25),
		.OWIDTH(21),
		.LGSPAN(2),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_o32.hex"})
		// }}}

) 	stage_o16(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s32),
		.i_data(w_o32),
		.o_data(w_o16),
		.o_sync(w_os16)
		// }}}
	);

	wire		w_s8;
	// verilator lint_off UNUSED
	wire		w_os8;
	// verilator lint_on  UNUSED
	wire	[43:0]	w_e8, w_o8;
	fftstage	#(
		// {{{
		.IWIDTH(21),
		.CWIDTH(25),
		.OWIDTH(22),
		.LGSPAN(1),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_e16.hex"})
		// }}}
	) stage_e8(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s16),
		.i_data(w_e16),
		.o_data(w_e8),
		.o_sync(w_s8)
		// }}}
	);
	fftstage	#(
		// {{{
		.IWIDTH(21),
		.CWIDTH(25),
		.OWIDTH(22),
		.LGSPAN(1),
		.BFLYSHIFT(0),
		.OPT_HWMPY(0),
		.CKPCE(1),
		.COEFFILE({`CHESHIRE_FFT_COEFF_ROOT,"/cmem_o16.hex"})
		// }}}

) 	stage_o8(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse), .o_inverse(),
		.i_sync(w_s16),
		.i_data(w_o16),
		.o_data(w_o8),
		.o_sync(w_os8)
		// }}}
	);

	wire		w_s4;
	// verilator lint_off UNUSED
	wire		w_os4;
	// verilator lint_on  UNUSED
	wire	[43:0]	w_e4, w_o4;
	qtrstage	#(
		// {{{
		.IWIDTH(22),
		.OWIDTH(22),
		.LGWIDTH(12),
		.ODD(0),
		.INVERSE(0),
		.SHIFT(0)
		// }}}
	) stage_e4(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse),
		.i_sync(w_s8),
		.i_data(w_e8),
		.o_data(w_e4),
		.o_sync(w_s4)
		// }}}
	);
	qtrstage	#(
		// {{{
		.IWIDTH(22),
		.OWIDTH(22),
		.LGWIDTH(12),
		.ODD(1),
		.INVERSE(0),
		.SHIFT(0)
		// }}}
	) stage_o4(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_inverse(i_inverse),
		.i_sync(w_s8),
		.i_data(w_o8),
		.o_data(w_o4),
		.o_sync(w_os4)
		// }}}
	);
	// verilator lint_off UNUSED
	wire		w_s2;
	// verilator lint_on  UNUSED
	wire	[45:0]	w_e2, w_o2;
	laststage	#(
		// {{{
		.IWIDTH(22),
		.OWIDTH(23),
		.SHIFT(1)
		// }}}
	) stage_2(
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_sync(w_s4),
		.i_left(w_e4), .i_right(w_o4),
		.o_left(w_e2), .o_right(w_o2),
		.o_sync(w_s2)
		// }}}
	);


	wire	br_start;
	reg	r_br_started;
	initial	r_br_started = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		r_br_started <= 1'b0;
	else if (i_ce)
		r_br_started <= r_br_started || w_s2;
	assign	br_start = r_br_started || w_s2;

	// Now for the bit-reversal stage.
	bitreverse	#(
		// {{{
		.LGSIZE(12),
		.WIDTH(23)
		// }}}
	) revstage (
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce & br_start),
		.i_in_0(w_e2),
		.i_in_1(w_o2),
		.o_out_0(br_left),
		.o_out_1(br_right),
		.o_sync(br_sync)
		// }}}
	);


	// Last clock: Register our outputs, we're done.
	initial	o_sync  = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		o_sync  <= 1'b0;
	else if (i_ce)
		o_sync  <= br_sync;

	always @(posedge i_clk)
	if (i_ce)
	begin
		o_left  <= br_left;
		o_right <= br_right;
	end


endmodule
