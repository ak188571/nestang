`timescale 1ns/1ps
module tb_crt_video;
    reg clk=0,clk_pixel=0,resetn=0;
    always #23 clk=~clk;always #3 clk_pixel=~clk_pixel;
    reg [5:0] color=0;
    reg [8:0] cycle=0,scanline=0;
    reg run_video=1;
    always @(posedge clk)begin
      if(run_video)begin
        color<=color+1'b1;
        if(cycle==340)begin cycle<=0;scanline<=scanline==261?0:scanline+1'b1;end
        else cycle<=cycle+1'b1;
      end
    end
    reg overlay=0,osd_window_toggle=0;
    reg [31:0] core_config=0;
    reg [31:0] osd_window=32'h0101100a;
    wire [7:0] nx,ny,bx,by;
    wire nv,bv;
    wire [31:0] applied;
    nes2hdmi current(.clk(clk),.resetn(resetn),.color(color),.cycle(cycle),.scanline(scanline),
        .sample(16'h1234),.aspect_8x7(1'b0),.core_config(core_config),.crt_config_applied(applied),.overlay(overlay),
        .osd_window(osd_window),.osd_window_toggle(osd_window_toggle),.osd_visible(nv),
        .overlay_x(nx),.overlay_y(ny),.overlay_color(15'h7c1f),
        .clk_pixel(clk_pixel),.clk_5x_pixel(clk_pixel));
    baseline_nes2hdmi baseline(.clk(clk),.resetn(resetn),.color(color),.cycle(cycle),.scanline(scanline),
        .sample(16'h1234),.aspect_8x7(1'b0),.overlay(overlay),
        .osd_window(osd_window),.osd_window_toggle(osd_window_toggle),.osd_visible(bv),
        .overlay_x(bx),.overlay_y(by),.overlay_color(15'h7c1f),
        .clk_pixel(clk_pixel),.clk_5x_pixel(clk_pixel));
    integer checks=0,game_pixels=0,osd_pixels=0,off_pixels=0;
    integer strength_pixels[0:3]='{0,0,0,0};
    reg [23:0] center,left;
    reg active_sample,osd_sample;
    reg [10:0] x_sample;
    reg [31:0] config_sample;
    always @(posedge clk_pixel)begin
        left<=center;
        center<=baseline.NES_PALETTE[baseline.mem_portB_rdata];
        active_sample<=baseline.active;osd_sample<=baseline.osd_pixel;
        x_sample<=baseline.cx;config_sample<=current.crt_config_active;
    end
    function automatic [23:0] reference_rgb(input [23:0] l,c,r,input integer strength);
        integer denominator,result;
        begin
            denominator=strength==1?16:strength==2?8:4;
            for(integer channel=0;channel<3;channel++)begin
                result=strength==0?int'(c[channel*8+:8]):
                    (int'(l[channel*8+:8])+(denominator-2)*int'(c[channel*8+:8])+
                     int'(r[channel*8+:8])+denominator/2)/denominator;
                reference_rgb[channel*8+:8]=8'(result);
            end
        end
    endfunction
    initial begin
        reg [23:0] expected,right;
        integer strength;
        repeat(10)@(negedge clk);resetn=1;
        for(integer k=0;k<9000000;k=k+1)begin
            @(negedge clk_pixel);
            // Expected neighbors come from the pinned legacy scaler/framebuffer,
            // not from the new prefetch path or the filter's history registers.
            right=baseline.NES_PALETTE[baseline.mem_portB_rdata];
            strength=config_sample[16]?int'(config_sample[18:17]):0;
            expected=!active_sample?24'h303030:osd_sample?24'hf800f8:
                reference_rgb(x_sample==160?center:left,center,x_sample==1119?center:right,strength);
            if(k>3 && current.rgb!==expected)$fatal(1,"RGB differs x=%0d y=%0d strength=%0d got=%h expected=%h",x_sample,current.cy,strength,current.rgb,expected);
            if(k>3 && strength==0)begin
                if(current.rgb!==baseline.rgb)$fatal(1,"OFF changed legacy pixel or phase");
                off_pixels++;
            end
            if({nx,ny,nv}!=={bx,by,bv})$fatal(1,"OSD coordinates changed");
            if(current.osd_pixel)osd_pixels=osd_pixels+1;
            if(active_sample&&!osd_sample)begin game_pixels++;strength_pixels[strength]++;end
            if(k==500000)begin overlay=1;osd_window_toggle=~osd_window_toggle;end
            if(k==1500000)core_config=32'h001f1234 & ~32'h10000; // enable OFF, all strength bits set
            // A centered filter samples its right neighbor early. Freeze only
            // during the independent spatial comparison, avoiding ambiguous
            // dual-clock framebuffer read/write collisions. Bypass is tested
            // with continuous writes both before and after the effect tests.
            if(k==2500000)run_video=0;
            if(k==2750000)core_config=32'h00131234; // weak, with reserved scanline bits
            if(k==4000000)core_config=32'h00151234; // standard
            if(k==5250000)core_config=32'h00171234; // strong
            if(k==6500000)core_config=32'h00191234; // enable ON, blur OFF, scanline ignored
            if(k==7750000)begin overlay=0;run_video=1;end
            checks=checks+1;
        end
        if(game_pixels<10000||osd_pixels<10000)$fatal(1,"insufficient game or OSD coverage");
        for(integer s=0;s<4;s++)if(strength_pixels[s]<10000)$fatal(1,"strength %0d not covered",s);
        $display("CRT video PASS: pinned legacy reference, exact OFF RGB/phase, centered blur all strengths, OSD unaffected, game/margins/line boundaries; pixels=%0d bypass=%0d game=%0d osd=%0d",checks,off_pixels,game_pixels,osd_pixels);$finish;
    end
endmodule
