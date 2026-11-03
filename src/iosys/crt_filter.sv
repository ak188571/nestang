// Centered three-tap horizontal blur, after scaling and before OSD composition.
// When enabled, rgb_in is prefetched one output pixel ahead, compensating the
// center register. In bypass, the caller retains its original read address and
// rgb_in passes straight through, including during live framebuffer writes.
module crt_filter (
    input wire pclk, resetn,
    input wire [23:0] rgb_in,
    input wire first_pixel, last_pixel,
    input wire [31:0] config_active,
    output wire [23:0] rgb_out
);
    reg [23:0] center=0, previous=0;
    always @(posedge pclk) begin
        if (!resetn) begin center<=0;previous<=0;end
        else begin center<=rgb_in;previous<=center;end
    end
    wire [23:0] left=first_pixel?center:previous;
    wire [23:0] right=last_pixel?center:rgb_in;
    function automatic [7:0] channel;
        input [7:0] l,c,r;
        input [1:0] strength;
        reg [11:0] total;
        begin
            total=0;
            // Blend the base [1,2,1]/4 kernel by 1/4, 1/2, or 1.
            // Round to nearest (half up); no gamma conversion in this stage.
            case(strength)
                1: begin total={4'b0,l}+({4'b0,c}<<3)+({4'b0,c}<<2)+({4'b0,c}<<1)+{4'b0,r}+12'd8;channel=total[11:4];end
                2: begin total={4'b0,l}+({4'b0,c}<<2)+({4'b0,c}<<1)+{4'b0,r}+12'd4;channel=total[10:3];end
                3: begin total={4'b0,l}+({4'b0,c}<<1)+{4'b0,r}+12'd2;channel=total[9:2];end
                default: channel=c;
            endcase
        end
    endfunction
    wire [1:0] strength=config_active[16]?config_active[18:17]:2'b00;
    assign rgb_out=strength==0?rgb_in:
                   {channel(left[23:16],center[23:16],right[23:16],strength),
                    channel(left[15:8],center[15:8],right[15:8],strength),
                    channel(left[7:0],center[7:0],right[7:0],strength)};
endmodule
