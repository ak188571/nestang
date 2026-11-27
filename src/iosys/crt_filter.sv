// Centered three-tap horizontal blur, after scaling and before OSD composition.
// Blur uses three compensated stages: palette RGB, center history, and FIR
// result. The caller prefetches three pixels. Bypass retains its original read address and
// rgb_in passes straight through, including during live framebuffer writes.
// Scanline alone uses palette_q and requires one pixel of caller prefetch.
module crt_filter #(parameter ROW_GAINS=0, REGISTER_CONTROLS=0) (
    input wire pclk, resetn,
    input wire [23:0] rgb_in,
    input wire first_pixel, last_pixel,
    input wire [3:0] scan_depth, // 0..8 attenuation in sixteenths, from native row phase.
    input wire [31:0] config_active,
    output wire [23:0] rgb_out, filtered_only
);
    reg [23:0] palette_q=0, center=0, previous=0;
    always @(posedge pclk) begin
        if (!resetn) begin palette_q<=0;center<=0;previous<=0;end
        else begin palette_q<=rgb_in;center<=palette_q;previous<=center;end
    end
    wire [23:0] left=first_pixel?center:previous;
    wire [23:0] right=last_pixel?center:palette_q;
    function automatic [7:0] channel;
        input [7:0] l,c,r;
        input [1:0] strength;
        reg [11:0] total,weighted_center;
        reg [8:0] neighbors;
        reg [9:0] rounded_neighbors;
        begin
            total=0;weighted_center=0;rounded_neighbors=0;
            neighbors={1'b0,l}+{1'b0,r};
            // Blend the base [1,2,1]/4 kernel by 1/4, 1/2, or 1.
            // Round to nearest (half up); no gamma conversion in this stage.
            case(strength)
                1: begin
                    weighted_center=({4'b0,c}<<4)-({4'b0,c}<<1);
                    rounded_neighbors={1'b0,neighbors}+10'd8;
                    total=weighted_center+{2'b0,rounded_neighbors};channel=total[11:4];
                end
                2: begin
                    weighted_center=({4'b0,c}<<2)+({4'b0,c}<<1);
                    rounded_neighbors={1'b0,neighbors}+10'd4;
                    total=weighted_center+{2'b0,rounded_neighbors};channel=total[10:3];
                end
                3: begin
                    weighted_center={4'b0,c}<<1;
                    rounded_neighbors={1'b0,neighbors}+10'd2;
                    total=weighted_center+{2'b0,rounded_neighbors};channel=total[9:2];
                end
                default: channel=c;
            endcase
        end
    endfunction
    wire [1:0] requested_strength=config_active[16]?config_active[18:17]:2'b00;
    wire requested_scan=config_active[16] && |config_active[20:19];
    wire [1:0] strength;
    wire scan_enabled, has_blur;
    if(REGISTER_CONTROLS)begin : frame_controls
        // The mailbox changes at x=0. Decode once before the first game pixel.
        reg [1:0] strength_q=0;
        reg scan_q=0, blur_q=0;
        always @(posedge pclk)begin
            strength_q <= requested_strength;
            scan_q <= requested_scan;
            blur_q <= |requested_strength;
        end
        assign strength=strength_q;
        assign has_blur=blur_q;
        assign scan_enabled=scan_q;
    end else begin : direct_controls
        assign strength=requested_strength;
        assign has_blur=|requested_strength;
        assign scan_enabled=requested_scan;
    end
    wire [23:0] blurred=!has_blur?rgb_in:
                   {channel(left[23:16],center[23:16],right[23:16],strength),
                    channel(left[15:8],center[15:8],right[15:8],strength),
                    channel(left[7:0],center[7:0],right[7:0],strength)};
    // Split palette/blur from gain so that they meet the pixel clock.
    // Use the result register for every enabled blur, including scanline OFF.
    // This eliminates the long unregistered FIR path to final RGB.
    reg [23:0] blurred_q=0;
    always @(posedge pclk)begin
        if(!resetn)blurred_q<=0;else blurred_q<=blurred;
    end
    // Keep the unregistered blur path completely outside the gain arithmetic.
    // Selecting it before gain would leave a long (mode-incompatible) STA path.
    wire [23:0] scan_input=has_blur ? blurred_q:palette_q;
    function automatic [7:0] dim_channel;
        input [7:0] c;
        input [4:0] gain;
        reg [12:0] total;
        begin
            total=c*gain+13'd8;
            dim_channel=total[11:4];
        end
    endfunction
    // Frame-applied core_config[21]: brightness-dependent scanline depth.
    // Use the source pixel at the FIR center. Capture its brightness class
    // alongside blurred_q (or palette_q when blur is disabled).
    wire [23:0] beam_pixel = has_blur ?  center : rgb_in;
    wire [3:0] luma = {2'b0, beam_pixel[23:22]} +
                      {1'b0, beam_pixel[15:14], 1'b0} +
                      {2'b0, beam_pixel[7:6]};
    reg [1:0] beam_class = 0;
    always @(posedge pclk) begin
        if (!resetn) beam_class <= 0;
        else beam_class <= luma[3:2];
    end
    // Middle band retains about 3/4 of the depth, highlights retain 1/2.
    wire [3:0] middle_depth = scan_depth - (({1'b0, scan_depth} + 5'd2) >> 2);
    wire [4:0] full_gain=5'd16-{1'b0,scan_depth};
    wire [4:0] mid_gain=5'd16-{1'b0,middle_depth};
    wire [4:0] high_gain=5'd16-{2'b0,scan_depth[3:1]};
    wire [4:0] base, mid, high;
    if (ROW_GAINS) begin : row_gain
        // Depth changes in the blank left margin. Precompute its three gains
        // before the game window, leaving the per-pixel beam class aligned.
        reg [4:0] base_q, mid_q, high_q;
        always @(posedge pclk) begin
            base_q<=full_gain; mid_q<=mid_gain; high_q<=high_gain;
        end
        assign base=base_q, mid=mid_q, high=high_q;
    end else begin : direct_gain
        assign base=full_gain, mid=mid_gain, high=high_gain;
    end
    wire [4:0] gain = !config_active[21] ? base :
                      beam_class[1] ? high : beam_class[0] ? mid : base;
    wire [23:0] scanned={dim_channel(scan_input[23:16],gain),
                    dim_channel(scan_input[15:8],gain),
                    dim_channel(scan_input[7:0],gain)};
    // Raw palette RGB never passes through the gain arithmetic. Master OFF
    // retains the exact legacy read timing; registered effect paths are compensated.
    assign rgb_out=scan_enabled?scanned:has_blur ? blurred_q:rgb_in;
    // The direct compositor uses this output only with scan or blur active.
    // Keep the unregistered palette bypass out of that registered filter path.
    assign filtered_only=scan_enabled ? scanned : blurred_q;
endmodule

// The RGB input is the converter's existing registered composite pixel.
// Register its per-channel mask in parallel, so no pixel delay is added.
module crt_phosphor_mask #(parameter CRT_REV=0) (
    input wire pclk, resetn,
    input wire before_first, odd_row, game_pixel, wide,
    input wire row_bank,
    input wire [1:0] mode, gamma_mode, temperature,
    input wire [23:0] game_rgb,
    input wire [23:0] composed_rgb,
    output wire [23:0] rgb_out
);
    // One-hot RGB order. Restart the pattern at the game's left edge on every row.
    reg [2:0] stripe = 3'b100;
    reg repeat_dot=0, next_triad=0;
    always @(posedge pclk) begin
        if (!resetn || before_first) next_triad<=0;
        else if (stripe[0] && (!wide || repeat_dot)) next_triad<=!next_triad;
        if (!resetn || before_first) repeat_dot<=0;
        else repeat_dot<=!repeat_dot;
        if (!resetn || before_first) stripe <= 3'b100;
        else if (!CRT_REV || !wide || repeat_dot) stripe <= {stripe[0], stripe[2:1]};
    end

    reg [2:0] full_strength = 3'b111;
    always @(posedge pclk) begin
        if (!resetn || !game_pixel) full_strength <= 3'b111;
        else case (mode)
            2'd1: full_strength <= stripe;
            2'd2: full_strength <= odd_row ? {stripe[0], stripe[2:1]} : stripe;
            // Three luminous rows and one bridge per triad. Adjacent
            // triads offset the bridge by two rows, like staggered slots.
            2'd3: full_strength <= !CRT_REV ? 3'b111 :
                    odd_row && (row_bank==next_triad) ? 3'b000 : stripe;
            default: full_strength <= 3'b111;
        endcase
    end
    // Decode the frame-latched word. Reserved value 3 bypasses each control.
    wire warm = temperature == 1, cool = temperature == 2;
    reg tone_enabled = 0;
    always @(posedge pclk)
        tone_enabled <= resetn && game_pixel &&
                        (gamma_mode == 1 || gamma_mode == 2 || warm || cool);

    // Read the transfer function on the same edge as the RGB compositor.
    // OSD, load text, borders and master OFF retain the composite pixel.
    for (genvar ch=0; ch<3; ch=ch+1) begin : phosphor_channel
        wire attenuate = (ch == 2) ? cool : (ch == 1) ? (warm || cool) : warm;
        wire [7:0] corrected;
        crt_tone_channel #(.GREEN(ch == 1)) tone(
            .pclk(pclk), .gamma_mode(gamma_mode), .attenuate(attenuate),
            .sample(game_rgb[8*ch +: 8]), .corrected(corrected));
        wire [7:0] sample = tone_enabled ? corrected : composed_rgb[8*ch +: 8];
        assign rgb_out[8*ch +: 8] = full_strength[ch] ? sample : (sample >> 1);
    end
endmodule

// Address = {gamma preset, white-point attenuation, input code}.
// 2048 x 8 fits one Gowin block RAM. Presets 0 and 3 use unity gamma.
module crt_tone_channel #(parameter GREEN = 0) (
    input wire pclk, attenuate,
    input wire [1:0] gamma_mode,
    input wire [7:0] sample,
    output reg [7:0] corrected
);
    reg [7:0] transfer [0:2047] /* synthesis syn_ramstyle="block_ram" */;
    generate if (GREEN) begin
        initial $readmemh("crt_tone_green.hex", transfer);
    end else begin
        initial $readmemh("crt_tone_rb.hex", transfer);
    end endgenerate
    always @(posedge pclk) corrected <= transfer[{gamma_mode, attenuate, sample}];
endmodule

// Screen-space effects for the active game rectangle. The control registers
// advance on the same edge as the converter's existing RGB compositor.
module crt_screen_edges #(
    parameter CURVATURE=0, RF_NOISE=0,
    parameter integer LEFT = 160, RIGHT = 1120, HEIGHT = 720
) (
    input wire pclk, resetn, game_pixel, vignette, rounded, overscan,
    input wire [31:0] widths,  // unsigned output pixels: top, bottom, left, right
    input wire [10:0] x,
    input wire [9:0] y,
    input wire [23:0] pixel,
    output wire [23:0] rgb_out,
    input wire curve_rim, rf
);
    // A 32-pixel quarter-circle sampled at pixel centers. The table gives
    // the number of pixels to replace at either end of this scanline.
    function automatic [4:0] corner_inset(input [4:0] row);
        case (row)
            5'd0: corner_inset = 5'd26;
            5'd1: corner_inset = 5'd22;
            5'd2: corner_inset = 5'd20;
            5'd3: corner_inset = 5'd17;
            5'd4: corner_inset = 5'd16;
            5'd5: corner_inset = 5'd14;
            5'd6: corner_inset = 5'd13;
            5'd7: corner_inset = 5'd11;
            5'd8: corner_inset = 5'd10;
            5'd9: corner_inset = 5'd9;
            5'd10: corner_inset = 5'd8;
            5'd11, 5'd12: corner_inset = 5'd7;
            5'd13: corner_inset = 5'd6;
            5'd14, 5'd15: corner_inset = 5'd5;
            5'd16: corner_inset = 5'd4;
            5'd17, 5'd18, 5'd19: corner_inset = 5'd3;
            5'd20, 5'd21: corner_inset = 5'd2;
            5'd22, 5'd23, 5'd24, 5'd25: corner_inset = 5'd1;
            default: corner_inset = 0;
        endcase
    endfunction

    // At x=0 there is ample time before the first game pixel on this line.
    wire [9:0] from_bottom = HEIGHT - 1 - y;
    wire [9:0] dy = (y < HEIGHT/2) ? y : from_bottom;
    reg [5:0] line_loss = 0;
    reg [4:0] inset = 0;
    always @(posedge pclk) begin
        if (x == 0) begin
            line_loss <= dy < 128 ? 6'd32 - dy[6:2] : 0;
            inset <= dy < 32 ? corner_inset(dy[4:0]) : 0;
        end
    end

    wire [10:0] from_left = x - LEFT;
    wire [10:0] from_right = RIGHT - 1 - x;
    wire [10:0] dx = x < (LEFT+RIGHT)/2 ? from_left : from_right;
    wire [5:0] column_loss = dx < 128 ? 6'd32 - dx[6:2] : 0;
    // Add receiver noise and a diagonal carrier beat to decoded NTSC.
    // Reserve 1/16 of the output range for interference, including on black.
    reg [15:0] grain=16'h1;
    wire [3:0] beat=x[3:0]+y[3:0];
    wire receiver=RF_NOISE && resetn && game_pixel && rf;
    reg [3:0] noise_q=0;
    always @(posedge pclk) begin
        grain<=resetn ? {grain[14:0],grain[15]^grain[13]^grain[12]^grain[10]} : 16'h1;
        noise_q<=receiver ? {beat[3],grain[2:0]} : 0;
    end
    wire [7:0] unity=receiver ? 8'd120 : 8'd128;
    reg [7:0] gain = 8'd128;
    wire cropped = y < widths[31:24] || from_bottom < widths[23:16] ||
                   from_left < widths[15:8] || from_right < widths[7:0];
    reg cut = 0;
    always @(posedge pclk) begin
        gain <= resetn && game_pixel && vignette ?
                unity - line_loss - column_loss : unity;
        cut <= resetn && game_pixel && ((CURVATURE && curve_rim) || (rounded && dx < inset) || (overscan && cropped));
    end

    // Unity gain retains every bit, including OSD and the existing phosphor mask.
    for (genvar c=0; c<3; c=c+1) begin : component
        wire [15:0] scaled = pixel[8*c +: 8] * gain;
        assign rgb_out[8*c +: 8] = cut ? 8'h30 : scaled[14:7]+noise_q;
    end
endmodule

// Three-tap horizontal chroma FIR. Preserve the current pixel's luma and
// average color difference at x, x-1, x-2 with weights 2,1,1. First-pixel
// replication prevents any sample from the preceding line entering the mix.
module crt_chroma_bleed (
    input wire pclk, first_pixel,
    input wire [23:0] rgb_in,
    output reg [23:0] rgb_out
);
    reg [23:0] source;
    reg first_source, first_sample;
    reg [31:0] sample, previous, older;
    reg [31:0] filtered;
    reg [7:0] center_luma;

    function automatic [7:0] luma(input [23:0] rgb);
        reg [9:0] sum;
        begin
            sum = {2'b0,rgb[23:16]} + {1'b0,rgb[15:8],1'b0} + {2'b0,rgb[7:0]} + 10'd2;
            luma = sum[9:2];
        end
    endfunction

    function automatic [7:0] average(input [7:0] current, near_left, far_left);
        reg [9:0] sum;
        begin
            sum = {1'b0,current,1'b0} + {2'b0,near_left} + {2'b0,far_left} + 10'd2;
            average = sum[9:2];
        end
    endfunction

    // Stage 1 isolates the existing scanline gain. Stage 2 packs Y with RGB.
    always @(posedge pclk) begin
        source <= rgb_in;
        first_source <= first_pixel;
        sample <= {luma(source),source};
        first_sample <= first_source;
        previous <= sample;
        older <= first_sample ? sample : previous;
        center_luma <= sample[31:24];
    end
    // Stage 3 filters the four components in parallel.
    for (genvar ch=0; ch<4; ch=ch+1) begin : tap
        wire [7:0] current = sample[8*ch +: 8];
        always @(posedge pclk)
            filtered[8*ch +: 8] <= first_sample ? current :
                average(current, previous[8*ch +: 8], older[8*ch +: 8]);
    end
    // Stage 4 restores the unfiltered luma and clips excursions at the RGB rails.
    for (genvar ch=0; ch<3; ch=ch+1) begin : reconstruct
        wire signed [9:0] value = $signed({2'b0,filtered[8*ch +: 8]}) +
                                 $signed({2'b0,center_luma}) - $signed({2'b0,filtered[31:24]});
        always @(posedge pclk)
            rgb_out[8*ch +: 8] <= value[9] ? 8'd0 : value[8] ? 8'd255 : value[7:0];
    end
endmodule

// Symmetric horizontal highlight halo in output pixels. The luma numerator
// uses five-bit channels with weights 1:2:1. Only its excess above 96 emits.
module crt_short_glow #(parameter BEAM_SPOT=0, CRT_REV=0) (
    input wire pclk, valid,
    input wire [23:0] pixel,
    output reg [23:0] result,
    input wire spot, halo, outer_row, focus, emission
);
    reg inside_game;
    reg [4:0] h0, h1, h2, h3, h4, lift;
    reg [23:0] c0, c1, c2, c3, center;
    // c0 isolates the scanline gain from the highlight adder.
    wire [6:0] light = {2'b0,c0[23:19]} + {1'b0,c0[15:11],1'b0} + {2'b0,c0[7:3]};
    wire [4:0] near_peak = h1 > h3 ? h1 : h3;
    wire [4:0] far_peak = (h0 > h4 ? h0 : h4) >> 1;
    always @(posedge pclk) begin
        inside_game <= valid;
        h0 <= (!BEAM_SPOT || halo) && inside_game && light[6:5] == 2'b11 ? light[4:0] : 5'd0;
        h1 <= h0; h2 <= h1; h3 <= h2; h4 <= h3;
        c0 <= pixel; c1 <= c0; c2 <= c1; c3 <= c2;

        lift <= near_peak > far_peak ? near_peak : far_peak;
    end
    for (genvar ch=0; ch<3; ch=ch+1) begin : channel
        if (BEAM_SPOT) begin : spot_profile
            // Each phosphor contributes a colored shoulder one HDMI pixel
            // to either side. Bright primaries emit even on a dark background.
            // A preset of overlapping phosphor primaries, with neutral
            // greys and the white point preserved exactly. Green receives
            // 1/16 red, red and blue each receive 1/8 green.
            wire [7:0] primary=c0[ch*8 +: 8];
            wire [7:0] adjacent=ch==1 ? c0[23:16] : c0[15:8];
            localparam SHIFT=ch==1 ? 4 : 3;
            wire [7:0] emitted=primary-(primary>>SHIFT)+(adjacent>>SHIFT);
            wire [7:0] source=CRT_REV>=5 && emission ? emitted : primary;
            wire [7:0] wing = (source >> 1) + (source[6] ? (source >> 3) : 8'd0);
            reg [7:0] w0,w1,w2,w3;
            reg [7:0] core1,core2,core3;
            reg valid1,valid2;
            reg [8:0] pair_sum,previous_pair;
            // Adjacent pair sums share the center sample. Replicate it at
            // the aperture limits so that blanking never enters the kernel.
            always @(posedge pclk) begin
                valid1<=inside_game; valid2<=valid1;
                pair_sum<={1'b0,(valid1 ? core1 : core2)}+
                          {1'b0,(valid2 ? core2 : core1)};
                previous_pair<=pair_sum;
            end
            wire [9:0] weighted={1'b0,pair_sum}+{1'b0,previous_pair}+10'd2;
            wire [7:0] focused=CRT_REV>=3 && focus ? weighted[9:2] : core3;
            always @(posedge pclk) begin
                w0 <= spot && inside_game && source[7] ? (outer_row ? wing >> 1 : wing) : 0;
                w1 <= w0; w2 <= w1; w3 <= w2;
                core1 <= spot && outer_row ? source - (source >> 2) : source;
                core2 <= core1; core3 <= core2;
                // w1 and w3 are the adjacent samples when core3 is centered.
                center[ch*8 +: 8] <= focused >= w1 && focused >= w3 ? focused :
                                      w1 >= w3 ? w1 : w3;
            end
        end else begin : glow_center
            always @(posedge pclk) center[ch*8 +: 8] <= c3[ch*8 +: 8];
        end
        wire [8:0] sum = {1'b0,center[ch*8 +: 8]} + {4'b0,lift};
        always @(posedge pclk) result[ch*8 +: 8] <= sum[8] ? 8'hff : sum[7:0];
    end
endmodule

// Inverse-map the 960 x 720 game aperture to the 256 x 224 source.
// Each axis contracts in proportion to squared distance on the other axis.
// Move only the reader ahead; HDMI and OSD keep their original clock and coordinates.
module crt_curvature #(parameter BLOOM_LATENCY=1)(input wire pclk, input wire [10:0] cx, input wire [9:0] cy,
    input wire blur, scan, bleed, glow, convergence, bloom, persistence,
    output reg [8:0] source_x, source_y, output wire outside_surface);
    function automatic [2:0] x_band(input [9:0] p);
        if(p<10'd17 || p>=10'd943) x_band=3'd7;
        else if(p<10'd55 || p>=10'd905) x_band=3'd6;
        else if(p<10'd95 || p>=10'd865) x_band=3'd5;
        else if(p<10'd141 || p>=10'd819) x_band=3'd4;
        else if(p<10'd193 || p>=10'd767) x_band=3'd3;
        else if(p<10'd258 || p>=10'd702) x_band=3'd2;
        else if(p<10'd352 || p>=10'd608) x_band=3'd1;
        else x_band=0;
    endfunction
    function automatic [2:0] y_band(input [9:0] p);
        if(p<10'd13 || p>=10'd707) y_band=3'd7;
        else if(p<10'd41 || p>=10'd679) y_band=3'd6;
        else if(p<10'd71 || p>=10'd649) y_band=3'd5;
        else if(p<10'd105 || p>=10'd615) y_band=3'd4;
        else if(p<10'd145 || p>=10'd575) y_band=3'd3;
        else if(p<10'd193 || p>=10'd527) y_band=3'd2;
        else if(p<10'd264 || p>=10'd456) y_band=3'd1;
        else y_band=0;
    endfunction
    reg [4:0] latency=0;
    reg [9:0] local_x=0, lookup_x=0, lookup_y=0;
    reg [2:0] row_band=0, column_band=0;
    reg [8:0] xmap[0:8191] /* synthesis syn_romstyle="block_rom" */;
    reg [8:0] ymap[0:8191] /* synthesis syn_romstyle="block_rom" */;
    initial begin
        $readmemh("crt_curve_x.hex",xmap);
        $readmemh("crt_curve_y.hex",ymap);
    end
    reg [19:0] rim_history=0;
    always @(posedge pclk)begin
        if(cx==32)begin
            latency <= (glow ? 4'd6 : 0) + (bleed ? 4'd4 : 0) +
                       (blur ? 4'd3 : scan ? 4'd1 : 0) + convergence + persistence + (bloom ? BLOOM_LATENCY : 0);
            row_band<=y_band(cy);
            lookup_y<=cy;
        end
        // At cx=65 the local index is 65-160+3+latency (modulo 1024).
        // The three clocks cover the index register, map ROM and framebuffer.
        if(cx==64)local_x<=10'd932+latency;
        else local_x<=local_x+1'b1;
        lookup_x<=local_x;
        column_band<=x_band(local_x);
        source_x<=xmap[{row_band,lookup_x}];
        source_y<=ymap[{column_band,lookup_y}];
        rim_history<={rim_history[18:0],source_x[8] || source_y[8]};
    end
    assign outside_surface=rim_history[latency];
endmodule

// The game stream arrives one pixel early when this stage is enabled. Green
// stays centered. Red points outward and blue inward in the outer quarters.
// At the ends of a scanline replicate the nearest game pixel.
module crt_convergence #(parameter LEFT=160, RIGHT=1120)(
    input wire pclk, enabled, input wire [10:0] x, input wire [9:0] y, input wire position_mode,
    input wire [23:0] ahead, output wire [23:0] pixel
);
    reg [23:0] center=0;
    reg [7:0] previous_r=0, previous_b=0;
    reg red_ahead=1, red_center=0, red_previous=0;
    reg blue_ahead=1, blue_center=0, blue_previous=0;
    reg keep_center_green=0;
    // The red/blue displacement reaches farther in from the four corners.
    // Latch zone limits in horizontal blanking, well ahead of game pixels.
    reg [10:0] left_end=LEFT+(RIGHT-LEFT)/4-1,right_start=RIGHT-(RIGHT-LEFT)/4-1;
    always @(posedge pclk) if(x==32)begin
        if(!position_mode)begin left_end<=LEFT+(RIGHT-LEFT)/4-1;right_start<=RIGHT-(RIGHT-LEFT)/4-1;end
        else if(y<100 || y>=620)begin left_end<=LEFT+359;right_start<=RIGHT-361;end
        else if(y<200 || y>=520)begin left_end<=LEFT+223;right_start<=RIGHT-225;end
        else begin left_end<=LEFT+95;right_start<=RIGHT-97;end
    end
    wire left_zone = x >= LEFT-1 && x < left_end;
    wire right_zone = x >= right_start && x < RIGHT-1;
    always @(posedge pclk) begin
        center <= ahead;
        previous_r <= center[23:16];
        previous_b <= center[7:0];
        // Decide each channel's tap before the new game sample arrives.
        red_ahead <= !enabled || left_zone;
        red_center <= enabled && !left_zone && !right_zone;
        red_previous <= enabled && right_zone;
        blue_ahead <= !enabled || (right_zone && x!=RIGHT-2);
        blue_previous <= enabled && left_zone && x!=LEFT-1;
        blue_center <= enabled && ((!left_zone && !right_zone) || x==LEFT-1 || x==RIGHT-2);
        keep_center_green <= enabled;
    end
    assign pixel[23:16]=({8{red_ahead}} & ahead[23:16]) | ({8{red_center}} & center[23:16]) | ({8{red_previous}} & previous_r);
    assign pixel[15:8]=keep_center_green ? center[15:8] : ahead[15:8];
    assign pixel[7:0]=({8{blue_ahead}} & ahead[7:0]) | ({8{blue_center}} & center[7:0]) | ({8{blue_previous}} & previous_b);
endmodule

// Sampled NTSC-style composite at two samples per native dot, three per carrier
// cycle. The quadrature axes approximate B-Y and R-Y. With Y=(R+2G+B)/4
// the three carrier samples are Y+V/2, Y-V/4+U/2, Y-V/4-U/2.
// A three-sample box decoder centered at the start of a dot takes one sample
// from the previous dot. By linearity, mix 3/8 of its decoded result into RGB
// by applying the inverse transform to that one sample's change. This retains
// flat colors exactly and produces both cross-color and cross-luminance.
module crt_ntsc_composite #(parameter ADDR_WIDTH=16, DEPTH=61440)(
    input wire clk, pclk, write_pixel, first_row, enable, frame_start,
    input wire [ADDR_WIDTH-1:0] write_addr, read_addr,
    input wire [23:0] native_rgb, raw_rgb,
    output wire [23:0] pixel,corrected_pixel,
    output wire correction_active
);
    function automatic [1:0] next_phase(input [1:0] p);
        next_phase=p==2 ? 0 : p+1'b1;
    endfunction
    function automatic signed [10:0] composite_sample(input [23:0] rgb,input [1:0] phase);
        reg signed [10:0] r,g,b,y,u,v;
        begin
            r=$signed({1'b0,rgb[23:16]});g=$signed({1'b0,rgb[15:8]});b=$signed({1'b0,rgb[7:0]});
            y=(r+(g<<<1)+b)>>>2;
            u=b-y;v=r-y;
            case(phase)
                0: composite_sample=y+(v>>>1);
                1: composite_sample=y-(v>>>2)+(u>>>1);
                default: composite_sample=y-(v>>>2)-(u>>>1);
            endcase
        end
    endfunction
    function automatic [4:0] quantize(input [7:0] base,input signed [12:0] correction);
        reg signed [12:0] level;
        begin
            level=$signed({1'b0,base})+correction;
            quantize=level<0 ? 0 : level>255 ? 31 : level[7:3];
        end
    endfunction
    reg [1:0] frame_phase=0,line_phase=0,phase=0;
    wire first_dot=write_addr[7:0]==0;
    wire [1:0] line_origin=first_row ? frame_phase : line_phase;
    reg [23:0] previous=0;
    reg [23:0] rgb1,rgb2,rgb3;
    reg [ADDR_WIDTH-1:0] addr1,addr2,addr3;
    reg [1:0] phase1,phase2;
    reg valid1=0,valid2=0,valid3=0;
    reg signed [10:0] left1,here1;
    reg signed [12:0] delta2;
    reg signed [12:0] red3,green3,blue3;
    always @(posedge clk)begin
        valid1<=write_pixel;valid2<=valid1;valid3<=valid2;
        if(write_pixel)begin
            previous<=native_rgb;
            if(first_dot)begin
                if(first_row) frame_phase<=next_phase(frame_phase);
                line_phase<=next_phase(line_origin);
                phase<=next_phase(next_phase(line_origin));
            end else phase<=next_phase(next_phase(phase));
            phase1<=phase;
            left1<=composite_sample(first_dot ? native_rgb : previous,phase);
            here1<=composite_sample(native_rgb,phase);
            rgb1<=native_rgb;addr1<=write_addr;
        end
        delta2<=$signed(left1)-$signed(here1);
        rgb2<=rgb1;addr2<=addr1;phase2<=phase1;
        case(phase2)
            0:begin red3<=((delta2<<<2)+delta2)>>>3;green3<=(-delta2)>>>3;blue3<=delta2>>>3;end
            1:begin red3<=(-delta2)>>>3;green3<=delta2>>>4;blue3<=delta2>>>1;end
            default:begin red3<=(-delta2)>>>3;green3<=((delta2<<<3)-delta2)>>>4;blue3<=(-delta2)>>>2;end
        endcase
        rgb3<=rgb2;addr3<=addr2;
    end
    wire [14:0] corrected={quantize(rgb3[23:16],red3),quantize(rgb3[15:8],green3),quantize(rgb3[7:0],blue3)};
    wire changed=corrected!={rgb3[23:19],rgb3[15:11],rgb3[7:3]};
    reg [15:0] decoded[0:DEPTH-1] /* synthesis syn_ramstyle="block_ram" */;
    // Keep the boot image until all history addresses have been written.
    reg seen_start=0, primed=0;
    always @(posedge clk)begin
        if(write_pixel && first_dot && first_row)seen_start<=1;
        if(valid3)begin
            decoded[addr3]<={changed,corrected};
            if(seen_start && addr3==DEPTH-1)primed<=1;
        end
    end
    (* async_reg="true" *) reg [1:0] ready_sync=0;
    reg display_ready=0;
    always @(posedge pclk)begin
        ready_sync<={ready_sync[0],primed};
        if(frame_start)display_ready<=ready_sync[1];
    end
    reg [15:0] sample;
    always @(posedge pclk)sample<=decoded[read_addr];
    assign correction_active=enable && display_ready && sample[15];
    assign corrected_pixel={sample[14:10],3'b0,sample[9:5],3'b0,sample[4:0],3'b0};
    assign pixel=correction_active ? corrected_pixel : raw_rgb;
endmodule
