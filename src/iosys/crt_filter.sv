// Stage 1: explicit, zero-latency bypass. All configurations preserve RGB.
// Effects are intentionally absent; CRTSTG1 must not be advertised as CRT ON.
module crt_filter (
    input wire [23:0] rgb_in,
    input wire [31:0] config_active,
    output wire [23:0] rgb_out
);
    assign rgb_out=rgb_in;
endmodule
