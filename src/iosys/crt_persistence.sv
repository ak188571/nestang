// One decay step per native game raster, independent of HDMI scaling and pauses.
module crt_persistence #(
    parameter HEIGHT=240, DISPLAY_BITS=16, BLOOM_DELAY=4
)(
    input wire clk, pclk, resetn, requested, write_pixel, frame_start, bloom,
    input wire [15:0] upcoming_addr,
    input wire [DISPLAY_BITS-1:0] read_addr,
    input wire [23:0] native_rgb, base_rgb,
    output reg [23:0] pixel
);
    localparam DEPTH=HEIGHT*256;
    localparam DISPLAY_DEPTH=DISPLAY_BITS==16 ? DEPTH : 1<<DISPLAY_BITS;
    localparam [15:0] LAST=DEPTH-1;
    reg [15:0] address;
    reg [8:0] history [0:DEPTH-1] /* synthesis syn_ramstyle="block_ram" */;
    reg [8:0] old_peak;
    reg started=0, primed=0;
    always @(posedge clk) begin
        // The native framebuffer registers its address and data on this edge.
        address<=upcoming_addr;
        old_peak<=history[upcoming_addr];
        if(!resetn || !requested) begin
            started<=0;
            primed<=0;
        end else if(write_pixel) begin
            if(address==0) started<=1;
            if(address==LAST && started) primed<=1;
        end
    end
    wire [8:0] next_peak, tail;
    for(genvar ch=0;ch<3;ch=ch+1) begin : phosphor
        wire [2:0] old=primed ? old_peak[3*ch +: 3] : 3'd0;
        wire [2:0] fresh=native_rgb[8*ch+5 +: 3];
        wire [2:0] faded={1'b0,old[2:1]};
        assign next_peak[3*ch +: 3]=fresh>=faded ? fresh : faded;
        // Stationary pixels keep their precise RGB/NTSC/Bloom values.
        assign tail[3*ch +: 3]=old>native_rgb[8*ch+4 +: 4] ? old : 3'd0;
    end
    // The reader uses the same framebuffer address and write edge as game RGB.
    // On SNES only the display copy wraps at 32 rows; the history is a full field.
    reg [8:0] display_tail [0:DISPLAY_DEPTH-1] /* synthesis syn_ramstyle="block_ram" */;
    always @(posedge clk) if(write_pixel) begin
        history[address]<=next_peak;
        display_tail[address[DISPLAY_BITS-1:0]]<=tail;
    end
    (* async_reg="true" *) reg [1:0] ready_sync=0;
    reg ready=0;
    reg [8:0] stages[0:BLOOM_DELAY];
    always @(posedge pclk) begin
        ready_sync<={ready_sync[0],primed};
        if(!resetn) ready<=0;
        else if(frame_start) ready<=ready_sync[1];
        stages[0]<=display_tail[read_addr];
        for(integer i=1;i<=BLOOM_DELAY;i=i+1) stages[i]<=stages[i-1];
    end
    wire [8:0] aligned=bloom ? stages[BLOOM_DELAY] : stages[0];
    for(genvar c=0;c<3;c=c+1) begin : output_channel
        wire [7:0] light={1'b0,aligned[3*c +: 3],4'b0};
        wire [7:0] base=base_rgb[8*c +: 8];
        always @(posedge pclk) pixel[8*c +: 8]<=ready && light>base ? light : base;
    end
endmodule
