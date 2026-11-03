`timescale 1ns/1ps
module tb_crt_scan_video;
    reg clk=0,clk_pixel=0,resetn=0;
    always #23 clk=~clk;always #3 clk_pixel=~clk_pixel;
    reg [5:0] color=0;
    reg [8:0] cycle=0,scanline=0;
    reg run_video=1;
    always @(posedge clk)if(run_video)begin
        color<=color+1'b1;
        if(cycle==340)begin cycle<=0;scanline<=scanline==261?0:scanline+1'b1;end
        else cycle<=cycle+1'b1;
    end
    reg overlay=0,osd_window_toggle=0;
    reg [31:0] core_config=0,osd_window=32'h0101100a;
    wire [31:0] applied;
    wire [7:0] nx,ny,bx,by,ax,ay;
    wire nv,bv,av;
    nes2hdmi current(.clk(clk),.resetn(resetn),.color(color),.cycle(cycle),.scanline(scanline),
        .sample(16'h1234),.aspect_8x7(1'b0),.core_config(core_config),.crt_config_applied(applied),
        .overlay(overlay),.osd_window(osd_window),.osd_window_toggle(osd_window_toggle),.osd_visible(nv),
        .overlay_x(nx),.overlay_y(ny),.overlay_color(15'h7c1f),.clk_pixel(clk_pixel),.clk_5x_pixel(clk_pixel));
    baseline_nes2hdmi baseline(.clk(clk),.resetn(resetn),.color(color),.cycle(cycle),.scanline(scanline),
        .sample(16'h1234),.aspect_8x7(1'b0),.overlay(overlay),.osd_window(osd_window),
        .osd_window_toggle(osd_window_toggle),.osd_visible(bv),.overlay_x(bx),.overlay_y(by),
        .overlay_color(15'h7c1f),.clk_pixel(clk_pixel),.clk_5x_pixel(clk_pixel));
    baseline4a_nes2hdmi baseline4a(.clk(clk),.resetn(resetn),.color(color),.cycle(cycle),.scanline(scanline),
        .sample(16'h1234),.aspect_8x7(1'b0),.core_config(core_config),.overlay(overlay),.osd_window(osd_window),
        .osd_window_toggle(osd_window_toggle),.osd_visible(av),.overlay_x(ax),.overlay_y(ay),
        .overlay_color(15'h7c1f),.clk_pixel(clk_pixel),.clk_5x_pixel(clk_pixel));
    reg [23:0] center,left,scan_early_rgb,scan_sample;
    reg [5:0] scan_early_data;
    reg active_sample,osd_sample;
    reg [3:0] depth_sample;
    reg [10:0] x_sample;
    reg [9:0] y_sample;
    reg [31:0] config_sample;
    always @(posedge clk_pixel)begin
        integer next_column,next_row;
        // Independently model a one-clock-early read using the pinned legacy
        // scaler state and its memory, including ongoing dual-clock writes.
        next_column=int'(baseline.xx);next_row=int'(baseline.yy);
        if((baseline.active||baseline.cx==159)&&baseline.xcnt>=704)next_column=(next_column+1)%256;
        if(baseline.cx==0)next_column=0;
        if(baseline.cy[0]!=baseline.cy_r[0]&&baseline.ycnt>=496)next_row=(next_row+1)%256;
        if(baseline.cy==0)next_row=0;
        scan_early_data<=baseline.mem[next_row*256+next_column+2048];
        scan_early_rgb<=baseline.NES_PALETTE[scan_early_data];scan_sample<=scan_early_rgb;
        left<=center;center<=baseline.NES_PALETTE[baseline.mem_portB_rdata];
        active_sample<=baseline.active;osd_sample<=baseline.osd_pixel;
        x_sample<=baseline.cx;y_sample<=baseline.cy;
        depth_sample<=current.scan_depth;config_sample<=current.crt_config_active;
    end
    function automatic [23:0] blur_ref(input [23:0] l,c,r,input integer level);
        integer denominator,value;
        begin
            denominator=level==1?16:level==2?8:4;
            for(integer ch=0;ch<3;ch++)begin
                value=level==0?int'(c[ch*8+:8]):
                    (int'(l[ch*8+:8])+(denominator-2)*int'(c[ch*8+:8])+int'(r[ch*8+:8])+denominator/2)/denominator;
                blur_ref[ch*8+:8]=8'(value);
            end
        end
    endfunction
    function automatic integer depth_ref(input integer row,input integer level);
        integer phase,upper,overlap,maximum;
        begin
            phase=(row*224)%720;upper=phase+224;
            if(upper>720)upper=720;
            if(phase<496)phase=496;
            overlap=upper>phase?upper-phase:0;
            maximum=level==0?0:level==1?2:level==2?4:8;
            depth_ref=(overlap*maximum+112)/224;
        end
    endfunction
    function automatic [23:0] scan_ref(input [23:0] rgb,input integer depth);
        integer value;
        begin
            for(integer ch=0;ch<3;ch++)begin
                value=(int'(rgb[ch*8+:8])*(16-depth)+8)/16;
                scan_ref[ch*8+:8]=8'(value);
            end
        end
    endfunction
    integer checked=0,legacy_checks=0,stage4a_checks=0,phase_frames=0;
    integer depth_sum[0:3];
    integer coverage[0:3][0:3];
    reg monitor=0;
    always @(negedge clk_pixel)if(monitor)begin
        reg [23:0] expected,right;
        integer blur,scan,depth;
        blur=config_sample[16]?int'(config_sample[18:17]):0;
        scan=config_sample[16]?int'(config_sample[20:19]):0;
        depth=depth_ref(int'(y_sample),scan);
        right=baseline.NES_PALETTE[baseline.mem_portB_rdata];
        expected=blur_ref(x_sample==160?center:left,center,x_sample==1119?center:right,blur);
        if(blur==0&&scan!=0)expected=scan_sample;
        expected=scan_ref(expected,depth);
        if(!active_sample)expected=24'h303030;
        else if(osd_sample)expected=24'hf800f8;
        if(current.rgb!==expected)$fatal(1,"scan video x=%0d y=%0d blur=%0d scan=%0d got=%h expected=%h",x_sample,y_sample,blur,scan,current.rgb,expected);
        if({nx,ny,nv}!=={bx,by,bv}||{nx,ny,nv}!=={ax,ay,av})$fatal(1,"OSD coordinate/visibility changed");
        if(blur==0&&scan==0)begin
            if(current.rgb!==baseline.rgb)$fatal(1,"legacy bypass changed");legacy_checks++;
        end
        if(scan==0)begin
            if(current.rgb!==baseline4a.rgb)$fatal(1,"scan OFF changed pinned stage4a");stage4a_checks++;
        end
        if(active_sample&&!osd_sample)coverage[blur][scan]++;
        if(x_sample==160 && y_sample<720)begin
            if(depth_sample!==4'(depth_ref(int'(y_sample),int'(config_sample[20:19]))))
                $fatal(1,"source row phase/depth mismatch y=%0d",y_sample);
            if(y_sample==0)for(integer level=0;level<4;level++)depth_sum[level]=0;
            for(integer level=0;level<4;level++)depth_sum[level]+=depth_ref(int'(y_sample),level);
            if(y_sample==719)begin
                if(depth_sum[0]!=0||depth_sum[1]!=448||depth_sum[2]!=896||depth_sum[3]!=1792)
                    $fatal(1,"native phase integrated attenuation mismatch");phase_frames++;
            end
        end
        checked++;
    end
    task automatic apply_config(input [31:0] value);
        integer tries;
        core_config=value;
        for(tries=0;tries<3000000;tries++)begin
            @(negedge clk_pixel);if(applied==value)return;
        end
        $fatal(1,"frame acknowledgement timeout");
    endtask
    initial begin
        for(integer b=0;b<4;b++)for(integer s=0;s<4;s++)coverage[b][s]=0;
        repeat(10)@(negedge clk);resetn=1;
        repeat(8)@(negedge clk_pixel);monitor=1;
        repeat(2500000)@(negedge clk_pixel);
        // Freeze writes only for the spatial blur reference comparison.
        run_video=0;repeat(20)@(negedge clk);
        overlay=1;osd_window_toggle=~osd_window_toggle;
        for(integer b=0;b<4;b++)for(integer s=0;s<4;s++)begin
            apply_config(32'h00011234|(32'(b)<<17)|(32'(s)<<19));
            repeat(1237500)@(negedge clk_pixel);
        end
        // Scanline-only uses a compensated one-clock-early read. Compare to the
        // independent early-read model during continuous source writes.
        apply_config(32'h00011234);run_video=1;
        for(integer s=1;s<4;s++)begin
            apply_config(32'h00011234|(32'(s)<<19));
            repeat(1237500)@(negedge clk_pixel);
        end
        apply_config(32'h001e1234);overlay=0;
        repeat(1237500)@(negedge clk_pixel);
        for(integer b=0;b<4;b++)for(integer s=0;s<4;s++)
            if(coverage[b][s]<10000)$fatal(1,"missing combination blur=%0d scan=%0d",b,s);
        if(phase_frames<16)$fatal(1,"insufficient phase coverage");
        $display("CRT scan video PASS: all 16 combinations, native224 integrated fractional phase, independent gain/early-read reference, pinned stage4a OFF equality, legacy bypass, frame-stable attenuation, live scan-only writes, OSD unchanged; pixels=%0d legacy=%0d stage4a=%0d phase_frames=%0d",checked,legacy_checks,stage4a_checks,phase_frames);
        $finish;
    end
    initial begin #2000000000;$fatal(1,"scan video timeout");end
endmodule
