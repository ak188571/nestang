// The NES has independent raster writer and HDMI reader. Read all 25 native
// neighbours at display time so a new pixel cannot inherit a two-line-old halo.
// Bank (x % 5, y % 5) is unique for every tap in a 5 by 5 window.
module crt_bloom_live(
    input wire clk,pclk,write_pixel,frame_start,
    input wire [7:0] upcoming_x,upcoming_y,
    input wire [15:0] write_addr,read_addr,
    input wire [23:0] native_rgb,game_rgb,
    output reg [23:0] result
);
    // The NES registers its write address and write enable one clock before
    // writing the framebuffer. Decode that same upcoming address in parallel.
    reg [8:0] write_map[0:255];
    reg [8:0] wx,wy;
    initial for(integer i=0;i<256;i=i+1)
        write_map[i]={3'(i%5),6'(i/5)};
    always @(posedge clk)begin
        wx<=write_map[upcoming_x];wy<=write_map[upcoming_y];
    end
    wire [5:0] luma={2'b0,native_rgb[23:20]}+{1'b0,native_rgb[15:12],1'b0}+{2'b0,native_rgb[7:4]};
    wire [2:0] highlight=luma[5] ? luma[4:2] : 0;
    reg started=0,complete=0;
    always @(posedge clk)if(write_pixel)begin
        if(write_addr==0)started<=1;
        if(write_addr==16'd61439 && started)complete<=1;
    end

    // A constant table selects the nearest address in each bank and gives it
    // weight 1,2,3,2,1. Out-of-image taps have zero weight, including corners.
    function automatic [7:0] tap(input integer center,bank,limit);
        integer d,pos;
        begin
            d=bank-center%5;
            if(d>2)d=d-5;
            if(d< -2)d=d+5;
            pos=center+d;
            tap=pos<0 || pos>=limit ? 0 : {6'(pos/5),2'(3-(d<0?-d:d))};
        end
    endfunction
    reg [39:0] xmap[0:255],ymap[0:255];
    initial for(integer i=0;i<256;i=i+1)begin
        for(integer b=0;b<5;b=b+1)begin
            xmap[i][8*b +: 8]=tap(i,b,256);
            ymap[i][8*b +: 8]=tap(i,b,240);
        end
    end
    reg [39:0] columns,rows;
    always @(posedge pclk)begin
        columns<=xmap[read_addr[7:0]];rows<=ymap[read_addr[15:8]];
    end
    function automatic [7:0] weight(input [5:0] value,input [1:0] factor);
        case(factor)
            1:weight=value;
            2:weight={value,1'b0};
            3:weight={value,1'b0}+value;
            default:weight=0;
        endcase
    endfunction
    wire [7:0] vertical[0:4];
    for(genvar r=0;r<5;r=r+1)begin : row_bank
        wire [4:0] horizontal[0:4];
        for(genvar c=0;c<5;c=c+1)begin : col_bank
            reg [2:0] intensity[0:4095] /* synthesis syn_ramstyle="block_ram" */;
            always @(posedge clk)
                if(write_pixel && wx[8:6]==c && wy[8:6]==r)
                    intensity[{wy[5:0],wx[5:0]}]<=highlight;
            reg [2:0] sample;
            reg [1:0] factor;
            always @(posedge pclk)begin
                sample<=intensity[{rows[8*r+2 +: 6],columns[8*c+2 +: 6]}];
                factor<=columns[8*c +: 2];
            end
            assign horizontal[c]=weight({3'd0,sample},factor);
        end
        reg [5:0] sum;
        reg [1:0] row_factor,aligned_factor;
        always @(posedge pclk)begin
            row_factor<=rows[8*r +: 2];aligned_factor<=row_factor;
            sum<=horizontal[0]+horizontal[1]+horizontal[2]+horizontal[3]+horizontal[4];
        end
        assign vertical[r]=weight(sum,aligned_factor);
    end
    reg [9:0] total;
    reg [23:0] base1,base2,base3;
    (* async_reg="true" *) reg [1:0] ready_sync=0;
    reg ready=0;
    always @(posedge pclk)begin
        ready_sync<={ready_sync[0],complete};
        if(frame_start)ready<=ready_sync[1];
        base1<=game_rgb;base2<=base1;base3<=base2;
        total<=vertical[0]+vertical[1]+vertical[2]+vertical[3]+vertical[4];
    end
    function automatic [7:0] add_light(input [7:0] base,input [5:0] light);
        reg [8:0] sum;
        begin sum={1'b0,base}+light;add_light=sum[8] ? 8'hff : sum[7:0];end
    endfunction
    wire [5:0] energy=!ready ? 6'd0 : |total[9:7] ? 6'd63 : total[6:1];
    always @(posedge pclk)
        result<={add_light(base3[23:16],energy),add_light(base3[15:8],energy-(energy>>2)),
                 add_light(base3[7:0],energy>>1)};
endmodule
