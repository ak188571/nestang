// NES video and sound to HDMI converter
// nand2mario, 2022.9

`timescale 1ns / 1ps

module nes2hdmi #(parameter OVERSCAN=0, GLOW=0, CURVATURE=0, CONVERGENCE=0, NTSC_COMPOSITE=0) (
	input clk,      // nes clock
	input resetn,

    // nes video signals
    input [5:0] color,
    input [8:0] cycle,
    input [8:0] scanline,
    input [15:0] sample,
    input aspect_8x7,       // 1: 8x7 pixel aspect ratio mode

    input [31:0] core_config,
    output [31:0] crt_config_applied,

    // overlay interface
    input overlay,
    input [31:0] osd_window,
    input osd_window_toggle,
    output osd_visible,

    output [7:0] overlay_x,
    output [7:0] overlay_y,
    input [14:0] overlay_color, // BGR5

	// video clocks
	input clk_pixel,
	input clk_5x_pixel,

    // output [7:0] led,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p,
    input [31:0] overscan_widths
);

// NES generates 256x240. We assume the center 256x224 is visible and scale that to 4:3 aspect ratio.
// https://www.nesdev.org/wiki/Overscan

localparam FRAMEWIDTH = 1280;
localparam FRAMEHEIGHT = 720;
localparam TOTALWIDTH = 1650;
localparam TOTALHEIGHT = 750;
localparam SCALE = 5;
localparam VIDEOID = 4;
localparam VIDEO_REFRESH = 60.0;

// localparam IDIV_SEL_X5 = 3;
// localparam FBDIV_SEL_X5 = 54;
// localparam ODIV_SEL_X5 = 2;
// localparam DUTYDA_SEL_X5 = "1000";
// localparam DYN_SDIV_SEL_X5 = 2;
  
localparam CLKFRQ = 74250;

localparam COLLEN = 80;
localparam AUDIO_BIT_WIDTH = 16;

localparam POWERUPNS = 100000000.0;
localparam CLKPERNS = (1.0/CLKFRQ)*1000000.0;
localparam int POWERUPCYCLES = $rtoi($ceil( POWERUPNS/CLKPERNS ));

// video stuff
wire [9:0] cy, frameHeight;
wire [10:0] cx, frameWidth;

//
// BRAM frame buffer
//
localparam MEM_DEPTH=256*240;
localparam MEM_ABITS=16;

logic [5:0] mem [0:256*240-1];
logic [15:0] mem_portA_addr;
    wire [8:0] curve_x,curve_y;
    wire curve_rim;
    wire curve_enabled;

logic [5:0] mem_portA_wdata;
logic mem_portA_we;

wire [15:0] mem_portB_addr;
logic [5:0] mem_portB_rdata;

// BRAM port A read/write
always_ff @(posedge clk) begin
    if (mem_portA_we) begin
        mem[mem_portA_addr] <= mem_portA_wdata;
    end
end

// BRAM port B read
always_ff @(posedge clk_pixel) begin
    mem_portB_rdata <= mem[mem_portB_addr];
end

initial begin
    $readmemb("background.txt", mem);
end


// 
// Data input and initial background loading
//
logic [8:0] r_scanline;
logic [8:0] r_cycle;
always @(posedge clk) begin
    r_scanline <= scanline;
    r_cycle <= cycle;
    mem_portA_we <= 1'b0;
    if ((r_scanline != scanline || r_cycle != cycle) && scanline < 9'd240 && ~cycle[8]) begin
        mem_portA_addr <= {scanline[7:0], cycle[7:0]};
        mem_portA_wdata <= color;
        mem_portA_we <= 1'b1;
    end
end

// audio stuff
//    localparam AUDIO_RATE=32000;        // weird only 32K sampling rate works
//    localparam AUDIO_RATE=96000;
localparam AUDIO_RATE=48000;
localparam AUDIO_CLK_DELAY = CLKFRQ * 1000 / AUDIO_RATE / 2;
logic [$clog2(AUDIO_CLK_DELAY)-1:0] audio_divider;
logic clk_audio;

always_ff@(posedge clk_pixel) 
begin
    if (audio_divider != AUDIO_CLK_DELAY - 1) 
        audio_divider++;
    else begin 
        clk_audio <= ~clk_audio; 
        audio_divider <= 0; 
    end
end

reg [15:0] audio_sample_word [1:0], audio_sample_word0 [1:0];
always @(posedge clk_pixel) begin       // crossing clock domain
    audio_sample_word0[0] <= sample;
    audio_sample_word[0] <= audio_sample_word0[0];
    audio_sample_word0[1] <= sample;
    audio_sample_word[1] <= audio_sample_word0[1];
end

//
// Video
// Scale 256x224 to 1280x720
//
localparam WIDTH=256;
localparam HEIGHT=240;
reg [23:0] composed_rgb;
wire [23:0] rgb;
reg active                  /* xsynthesis syn_keep=1 */;
reg [$clog2(WIDTH)-1:0] xx  /* xsynthesis syn_keep=1 */; // scaled-down pixel position
reg [$clog2(HEIGHT)-1:0] yy /* xsynthesis syn_keep=1 */;
reg [10:0] xcnt             /* xsynthesis syn_keep=1 */;
reg [10:0] ycnt             /* xsynthesis syn_keep=1 */;                  // fractional scaling counters
reg [9:0] cy_r;
// Keep the exact legacy read schedule in bypass, including read/write overlap.
// Prefetch three pixels for blur, one for scanline alone, zero for bypass.
wire blur_enabled=crt_config_active[16] && |crt_config_active[18:17];
wire scan_enabled=crt_config_active[16] && |crt_config_active[20:19];
// In the game interval 3*256 < 960, so at most one source column advances.
// The carry condition xcnt+768 >= 960 reduces to xcnt >= 192.
// Blank margins provide priming time at row boundaries before x=160.
wire [7:0] xx_three=xx+(xcnt>=11'd192 ? 8'd1 : 8'd0);
assign mem_portB_addr = curve_enabled ? {(8'd8+curve_y[7:0]),curve_x[7:0]} :
                            blur_enabled ? yy * WIDTH + xx_three + 8*256 :
                       scan_enabled ? yy_next * WIDTH + xx_next + 8*256 :
                                      yy * WIDTH + xx + 8*256;
// Integrate a one-output-pixel-wide dark band at each native source-row end.
// ycnt advances by 224 modulo 720, so every reachable phase is a multiple of 16.
// Band overlap with the output-row footprint is triangular, 0..224 (0..14 here).
// Quantized attenuation preserves its integrated strength over the 45-row cycle.
function automatic [3:0] native_scan_depth(input [10:0] phase,input [1:0] level);
    reg [5:0] index;
    reg [4:0] weight;
    begin
        index=phase[9:4];
        if(index<=17)weight=0;
        else if(index<31)weight=5'(index-17);
        else weight=5'(45-index);
        case(level)
            1:native_scan_depth=weight<4?0:weight<11?1:2;
            2:native_scan_depth=weight<2?0:weight<6?1:weight<9?2:weight<13?3:4;
            3:case(weight)
                0:native_scan_depth=0;
                1,2:native_scan_depth=1;
                3,4:native_scan_depth=2;
                5,6:native_scan_depth=3;
                7:native_scan_depth=4;
                8,9:native_scan_depth=5;
                10,11:native_scan_depth=6;
                12,13:native_scan_depth=7;
                default:native_scan_depth=8;
            endcase
            default:native_scan_depth=0;
        endcase
    end
endfunction
reg [3:0] scan_depth=0;
always @(posedge clk_pixel)begin
    if(!resetn)scan_depth<=0;
    else scan_depth<=native_scan_depth(ycnt,crt_config_active[20:19]);
end
wire osd_pixel;
tc_osd_layer osd_layer(.pclk(clk_pixel),.resetn(resetn),.cx(cx),.cy(cy),
    .active(overlay),.window(osd_window),.window_toggle(osd_window_toggle),
    .x(overlay_x),.y(overlay_y),.pixel(osd_pixel),.visible(osd_visible));
localparam XSTART = (1280 - 960) / 2;   // 960:720 = 4:3
localparam XSTOP = (1280 + 960) / 2;

localparam BLEED_LATENCY = 4;
localparam GLOW_LATENCY = 6;
// Capture the display mode before the first fetch on each line.
reg glow_enabled=0, bleed_enabled=0;
    reg convergence_enabled=0;
    always @(posedge clk_pixel) begin
        if(!resetn) convergence_enabled <= 0;
        else if(cx==1) convergence_enabled <= CONVERGENCE && crt_config_active[16] &&
                                               crt_config_active[13] && cy<FRAMEHEIGHT;
    end
reg display_raw=1, display_filtered=0, display_bleed=0;
wire row_glow = GLOW && crt_config_active[16] && crt_config_active[15] && cy < FRAMEHEIGHT;
wire row_bleed = crt_config_active[16] && crt_config_active[31] && cy < FRAMEHEIGHT;
always @(posedge clk_pixel) begin
    if(!resetn) begin
        glow_enabled <= 0;
        bleed_enabled <= 0;
        display_raw <= 1;
        display_filtered <= 0;
        display_bleed <= 0;
    end else if(cx==1) begin
        glow_enabled <= row_glow;
        bleed_enabled <= row_bleed;
        display_bleed <= !row_glow && row_bleed;
        display_filtered <= !row_glow && !row_bleed && (blur_enabled || scan_enabled);
        display_raw <= !row_glow && !row_bleed && !(blur_enabled || scan_enabled);
    end
end
// Advance only the game fetch. OSD, crop and HDMI keep physical screen coordinates.
generate if(CURVATURE) begin : curve_path
        crt_curvature map(.pclk(clk_pixel),.cx(cx),.cy(cy),.blur(blur_enabled),.scan(scan_enabled),
            .bleed(bleed_enabled),.glow(glow_enabled),.convergence(convergence_enabled),.source_x(curve_x),.source_y(curve_y),
            .outside_surface(curve_rim));
        assign curve_enabled=crt_config_active[16] && crt_config_active[14];
    end else begin : no_curve
        assign curve_x=0;assign curve_y=0;assign curve_rim=0;assign curve_enabled=0;
    end endgenerate
    wire [10:0] sample_x = cx + {8'd0,glow_enabled,glow_enabled,convergence_enabled};

wire fetch_start = bleed_enabled ? sample_x == XSTART-1-BLEED_LATENCY : sample_x == XSTART-1;
wire fetch_stop  = bleed_enabled ? sample_x == XSTOP-1-BLEED_LATENCY : sample_x == XSTOP-1;
reg early_active = 0;
always @(posedge clk_pixel) begin
    if (fetch_start) early_active <= 1;
    else if (fetch_stop) early_active <= 0;
end
wire early_fetch = early_active || fetch_start;

// Compute the original scaler's next state without changing its phase.
// Reading that address one pixel early compensates the CRT center register.
reg active_next;
reg [7:0] xx_next,yy_next;
reg [10:0] xcnt_next,ycnt_next;
always @* begin
    active_next=active;xx_next=xx;yy_next=yy;
    xcnt_next=xcnt;ycnt_next=ycnt;
    if(cx==XSTART-1)active_next=1;
    else if(cx==XSTOP-1)active_next=0;
    if((bleed_enabled || glow_enabled || convergence_enabled) ? early_fetch : (active || cx==XSTART-1))begin
        xcnt_next=xcnt+11'd256;
        if(xcnt_next>=960)begin xcnt_next=xcnt_next-11'd960;xx_next=xx+1'b1;end
    end
    if(cy[0]!=cy_r[0])begin
        ycnt_next=ycnt+11'd224;
        if(ycnt_next>=720)begin ycnt_next=ycnt_next-11'd720;yy_next=yy+1'b1;end
    end
    if(cx==0)begin xx_next=0;xcnt_next=0;end
    if(cy==0)begin yy_next=0;ycnt_next=0;end
end
always @(posedge clk_pixel)begin
    active<=active_next;xx<=xx_next;yy<=yy_next;
    xcnt<=xcnt_next;ycnt<=ycnt_next;cy_r<=cy;
end

// calc rgb value to hdmi
reg [23:0] NES_PALETTE [0:63];
wire [31:0] crt_config_active;
wire [31:0] overscan_active;
generate if (OVERSCAN) begin : overscan_config
    // Use the existing frame-boundary mailbox for the independent four-byte word.
    tc_crt_config widths(.clk(clk), .pclk(clk_pixel), .resetn(resetn),
        .requested(overscan_widths), .frame_start(cx==0 && cy==0),
        .active_config(overscan_active), .applied_config());
end else begin : no_overscan_config
    assign overscan_active=0;
end endgenerate
wire [23:0] decoded_rgb;
    generate if(NTSC_COMPOSITE) begin : ntsc_path
        reg enable=0,first_row=0;
        always @(posedge clk_pixel)if(cx==1)enable<=crt_config_active[16] && crt_config_active[12];
        always @(posedge clk)first_row<=scanline==0;
        crt_ntsc_composite #(.ADDR_WIDTH(MEM_ABITS),.DEPTH(MEM_DEPTH)) decoder(
            .clk(clk),.pclk(clk_pixel),.write_pixel(mem_portA_we),.first_row(first_row),
            .enable(enable),.frame_start(cx==0 && cy==0),.write_addr(mem_portA_addr),.read_addr(mem_portB_addr),
            .native_rgb(NES_PALETTE[mem_portA_wdata]),.raw_rgb(NES_PALETTE[mem_portB_rdata]),.pixel(decoded_rgb));
    end else assign decoded_rgb=NES_PALETTE[mem_portB_rdata];
    endgenerate
    wire [23:0] game_rgb_crt;
tc_crt_config crt_config(.clk(clk),.pclk(clk_pixel),.resetn(resetn),
    .requested(core_config),.frame_start(cx==0 && cy==0),
    .active_config(crt_config_active),.applied_config(crt_config_applied));
crt_filter #(.ROW_GAINS(GLOW),.REGISTER_CONTROLS(CONVERGENCE)) crt(.pclk(clk_pixel),.resetn(resetn),
    .first_pixel(bleed_enabled ? sample_x==(blur_enabled?XSTART-1-BLEED_LATENCY:XSTART-BLEED_LATENCY) : sample_x==(blur_enabled?XSTART-1:XSTART)),
    .last_pixel(bleed_enabled ? sample_x==(blur_enabled?XSTOP-2-BLEED_LATENCY:XSTOP-1-BLEED_LATENCY) : sample_x==(blur_enabled?XSTOP-2:XSTOP-1)),.scan_depth(scan_depth),
    .rgb_in(decoded_rgb),
    .config_active(crt_config_active),.rgb_out(game_rgb_crt));
wire [23:0] bleed_rgb;
crt_chroma_bleed bleed(.pclk(clk_pixel), .first_pixel(sample_x==XSTART-BLEED_LATENCY),
    .rgb_in(game_rgb_crt), .rgb_out(bleed_rgb));
wire [23:0] pre_glow_rgb = bleed_enabled ? bleed_rgb : game_rgb_crt;
wire [23:0] game_before_convergence, game_rgb_display;
    generate if(CONVERGENCE) begin : convergence_path
        crt_convergence #(.LEFT(XSTART),.RIGHT(XSTOP)) beams(
            .pclk(clk_pixel),.enabled(convergence_enabled),.x(cx),
            .ahead(game_before_convergence),.pixel(game_rgb_display));
    end else begin : no_convergence
        assign game_rgb_display=game_before_convergence;
    end endgenerate
generate if (GLOW) begin : glow_path
    wire [23:0] halo_rgb;
    crt_short_glow glow(.pclk(clk_pixel),
        .valid(convergence_enabled ? (cx >= XSTART-GLOW_LATENCY-1 && cx < XSTOP-GLOW_LATENCY-1) :
                   (cx >= XSTART-GLOW_LATENCY && cx < XSTOP-GLOW_LATENCY)),
        .pixel(pre_glow_rgb), .result(halo_rgb));
    assign game_before_convergence = ({24{display_raw}} & decoded_rgb) |
                                  ({24{display_filtered}} & game_rgb_crt) |
                                  ({24{display_bleed}} & bleed_rgb) |
                                  ({24{glow_enabled}} & halo_rgb);
end else begin : no_glow
    assign game_before_convergence = pre_glow_rgb;
end endgenerate
always @(posedge clk_pixel) begin
    if (active) begin
        if (osd_pixel)
            composed_rgb <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};       // BGR5 to RGB8
        else
            composed_rgb <= game_rgb_display;
    end else
        composed_rgb <= 24'h303030;
end

wire [23:0] phosphor_rgb;
crt_phosphor_mask phosphors(
    .pclk(clk_pixel), .resetn(resetn), .before_first(cx==XSTART-1),
    .odd_row(cy[0]), .game_pixel(crt_config_active[16] && active && cy<FRAMEHEIGHT && !osd_pixel),
    .game_rgb(game_rgb_display), .gamma_mode(crt_config_active[25:24]),
        .temperature(crt_config_active[27:26]), .mode(crt_config_active[23:22]), .composed_rgb(composed_rgb), .rgb_out(phosphor_rgb));
crt_screen_edges #(.CURVATURE(CURVATURE),.LEFT(XSTART), .RIGHT(XSTOP), .HEIGHT(FRAMEHEIGHT)) edges(
    .pclk(clk_pixel), .resetn(resetn), .game_pixel(crt_config_active[16] && active && cy<FRAMEHEIGHT && !osd_pixel),
    .curve_rim(curve_enabled && curve_rim),.vignette(crt_config_active[28]), .rounded(crt_config_active[29]),
    .overscan(crt_config_active[30]), .widths(overscan_active),
    .x(cx), .y(cy), .pixel(phosphor_rgb), .rgb_out(rgb));

// HDMI output.
logic[2:0] tmds;

hdmi #( .VIDEO_ID_CODE(VIDEOID), 
        .DVI_OUTPUT(0), 
        .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE), 
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .START_X(0),
        .START_Y(0) )

hdmi( .clk_pixel_x5(clk_5x_pixel), 
        .clk_pixel(clk_pixel), 
        .clk_audio(clk_audio),
        .rgb(rgb), 
        .reset( 0 ),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds), 
        .tmds_clock(tmdsClk), 
        .cx(cx), 
        .cy(cy),
        .frame_width( frameWidth ),
        .frame_height( frameHeight ) );

// Gowin LVDS output buffer
ELVDS_OBUF tmds_bufds [3:0] (
    .I({clk_pixel, tmds}),
    .O({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);

// 2C02 palette: https://www.nesdev.org/wiki/PPU_palettes
assign NES_PALETTE[0] = 24'h545454;  assign NES_PALETTE[1] = 24'h001e74;  assign NES_PALETTE[2] = 24'h081090;  assign NES_PALETTE[3] = 24'h300088;  
assign NES_PALETTE[4] = 24'h440064;  assign NES_PALETTE[5] = 24'h5c0030;  assign NES_PALETTE[6] = 24'h540400;  assign NES_PALETTE[7] = 24'h3c1800;
assign NES_PALETTE[8] = 24'h202a00;  assign NES_PALETTE[9] = 24'h083a00;  assign NES_PALETTE[10] = 24'h004000;  assign NES_PALETTE[11] = 24'h003c00;  
assign NES_PALETTE[12] = 24'h00323c;  assign NES_PALETTE[13] = 24'h000000;  assign NES_PALETTE[14] = 24'h000000;  assign NES_PALETTE[15] = 24'h000000;
assign NES_PALETTE[16] = 24'h989698;  assign NES_PALETTE[17] = 24'h084cc4;  assign NES_PALETTE[18] = 24'h3032ec;  assign NES_PALETTE[19] = 24'h5c1ee4;  
assign NES_PALETTE[20] = 24'h8814b0;  assign NES_PALETTE[21] = 24'ha01464;  assign NES_PALETTE[22] = 24'h982220;  assign NES_PALETTE[23] = 24'h783c00;
assign NES_PALETTE[24] = 24'h545a00;  assign NES_PALETTE[25] = 24'h287200;  assign NES_PALETTE[26] = 24'h087c00;  assign NES_PALETTE[27] = 24'h007628; 
assign NES_PALETTE[28] = 24'h006678;  assign NES_PALETTE[29] = 24'h000000;  assign NES_PALETTE[30] = 24'h000000;  assign NES_PALETTE[31] = 24'h000000;
assign NES_PALETTE[32] = 24'heceeec;  assign NES_PALETTE[33] = 24'h4c9aec;  assign NES_PALETTE[34] = 24'h787cec;  assign NES_PALETTE[35] = 24'hb062ec;  
assign NES_PALETTE[36] = 24'he454ec;  assign NES_PALETTE[37] = 24'hec58b4;  assign NES_PALETTE[38] = 24'hec6a64;  assign NES_PALETTE[39] = 24'hd48820;
assign NES_PALETTE[40] = 24'ha0aa00;  assign NES_PALETTE[41] = 24'h74c400;  assign NES_PALETTE[42] = 24'h4cd020;  assign NES_PALETTE[43] = 24'h38cc6c; 
assign NES_PALETTE[44] = 24'h38b4cc;  assign NES_PALETTE[45] = 24'h3c3c3c;  assign NES_PALETTE[46] = 24'h000000;  assign NES_PALETTE[47] = 24'h000000;
assign NES_PALETTE[48] = 24'heceeec;  assign NES_PALETTE[49] = 24'ha8ccec;  assign NES_PALETTE[50] = 24'hbcbcec;  assign NES_PALETTE[51] = 24'hd4b2ec;
assign NES_PALETTE[52] = 24'hecaeec;  assign NES_PALETTE[53] = 24'hecaed4;  assign NES_PALETTE[54] = 24'hecb4b0;  assign NES_PALETTE[55] = 24'he4c490;
assign NES_PALETTE[56] = 24'hccd278;  assign NES_PALETTE[57] = 24'hb4de78;  assign NES_PALETTE[58] = 24'ha8e290;  assign NES_PALETTE[59] = 24'h98e2b4;
assign NES_PALETTE[60] = 24'ha0d6e4;  assign NES_PALETTE[61] = 24'ha0a2a0;  assign NES_PALETTE[62] = 24'h000000;  assign NES_PALETTE[63] = 24'h000000;

endmodule
