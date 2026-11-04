`timescale 1ns/1ps
module tb_crt_scanline;
    reg pclk=0,resetn=1;
    always #3 pclk=~pclk;
    reg [23:0] rgb_in=0;
    reg first_pixel=0,last_pixel=0;
    reg [3:0] scan_depth=0;
    reg [31:0] config_active=0;
    wire [23:0] rgb_out;
    crt_filter dut(.*);
    integer checks=0;
    function automatic [23:0] reference_rgb(input [23:0] rgb,input integer depth);
        integer value;
        begin
            for(integer c=0;c<3;c++)begin
                value=(int'(rgb[c*8+:8])*(16-depth)+8)/16;
                reference_rgb[c*8+:8]=8'(value);
            end
        end
    endfunction
    initial begin
        for(integer enabled=0;enabled<2;enabled++)begin
            for(integer depth=0;depth<=8;depth++)begin
                for(integer level=0;level<4;level++)begin
                    for(integer v=0;v<256;v++)begin
                        @(negedge pclk);rgb_in={8'(v),8'(255-v),8'(v*77)};
                        config_active=(32'(level)<<19)|(enabled?32'h10000:0);
                        scan_depth=4'(depth);@(posedge pclk);#1;
                        if(rgb_out!==reference_rgb(rgb_in,enabled&&level!=0?depth:0))
                            $fatal(1,"scanline gain/rounding mismatch enable=%0d depth=%0d level=%0d rgb=%h got=%h",enabled,depth,level,rgb_in,rgb_out);
                        checks++;
                    end
                end
            end
        end
        @(negedge pclk);rgb_in=24'hffffff;scan_depth=8;config_active=32'h00190000;@(posedge pclk);#1;
        if(rgb_out!==24'h808080)$fatal(1,"strong white gain wrong");
         @(negedge pclk);rgb_in=0;@(posedge pclk);#1;if(rgb_out!==0)$fatal(1,"black lifted");
        $display("CRT scanline PASS: independent gain reference, all 8-bit values, all nine fractional depths, per-channel rounding, effect/master bypass, black/white; pixels=%0d",checks);
        $finish;
    end
endmodule
