`timescale 1ns/1ps
module tb_crt_video;
    reg clk=0,clk_pixel=0,resetn=0;
    always #23 clk=~clk;always #3 clk_pixel=~clk_pixel;
    reg [5:0] color=0;
    reg [8:0] cycle=0,scanline=0;
    always @(posedge clk)begin
        color<=color+1'b1;
        if(cycle==340)begin cycle<=0;scanline<=scanline==261?0:scanline+1'b1;end
        else cycle<=cycle+1'b1;
    end
    reg overlay=0,osd_window_toggle=0;
    reg [31:0] core_config=0;
    reg [31:0] osd_window=32'h0101100a;
    wire [7:0] nx,ny,bx,by;
    wire nv,bv;
    nes2hdmi current(.clk(clk),.resetn(resetn),.color(color),.cycle(cycle),.scanline(scanline),
        .sample(16'h1234),.aspect_8x7(1'b0),.core_config(core_config),.overlay(overlay),
        .osd_window(osd_window),.osd_window_toggle(osd_window_toggle),.osd_visible(nv),
        .overlay_x(nx),.overlay_y(ny),.overlay_color(15'h7c1f),
        .clk_pixel(clk_pixel),.clk_5x_pixel(clk_pixel));
    baseline_nes2hdmi baseline(.clk(clk),.resetn(resetn),.color(color),.cycle(cycle),.scanline(scanline),
        .sample(16'h1234),.aspect_8x7(1'b0),.overlay(overlay),
        .osd_window(osd_window),.osd_window_toggle(osd_window_toggle),.osd_visible(bv),
        .overlay_x(bx),.overlay_y(by),.overlay_color(15'h7c1f),
        .clk_pixel(clk_pixel),.clk_5x_pixel(clk_pixel));
    integer checks=0,game_pixels=0,osd_pixels=0;
    initial begin
        repeat(10)@(negedge clk);resetn=1;
        for(integer k=0;k<4000000;k=k+1)begin
            @(negedge clk_pixel);
            if(current.rgb!==baseline.rgb)$fatal(1,"RGB differs at x=%0d y=%0d",current.cx,current.cy);
            if({nx,ny,nv}!=={bx,by,bv})$fatal(1,"OSD coordinates changed");
            if(current.osd_pixel)osd_pixels=osd_pixels+1;
            if(current.active&&!current.osd_pixel&&current.rgb!=24'h303030)game_pixels=game_pixels+1;
            if(k==500000)begin overlay=1;osd_window_toggle=~osd_window_toggle;end
            if(k==1500000)core_config=32'h001f1234;
            if(k==2500000)overlay=0;
            checks=checks+1;
        end
        if(game_pixels<10000||osd_pixels<10000)$fatal(1,"insufficient game or OSD coverage");
        $display("CRT video PASS: RGB/OSD coordinates match pinned baseline pixels=%0d game=%0d osd=%0d",checks,game_pixels,osd_pixels);$finish;
    end
endmodule
