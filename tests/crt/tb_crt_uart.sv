`timescale 1ns/1ps
module tb_crt_uart;
    reg clk=0,hclk=0,resetn=0;
    always #5 clk=~clk;always #2 hclk=~hclk;
    reg uart_rx=1;
    wire uart_tx,overlay,osd_input_block;
    reg [11:0] joy1=0,joy2=0;
    wire [31:0] core_config,crt_config_applied,active_config;
    reg frame_start=0;
    iosys_bl616 #(.FREQ(32000000)) dut(
        .clk(clk),.hclk(hclk),.resetn(resetn),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .overlay(overlay),.osd_visible(1'b0),.osd_input_block(osd_input_block),
        .overlay_x(8'b0),.overlay_y(8'b0),.joy1(joy1),.joy2(joy2),
        .core_config(core_config),.crt_config_applied(crt_config_applied),
        .mgmt_readdata(16'b0),.fdd_request(2'b0));
    tc_crt_config config_path(.clk(clk),.pclk(hclk),.resetn(resetn),
        .requested(core_config),.frame_start(frame_start),
        .active_config(active_config),.applied_config(crt_config_applied));
    wire [7:0] byte_out;
    wire byte_ready;
    async_receiver #(.ClkFrequency(32000000),.Baud(2000000)) monitor(
        .clk(clk),.RxD(uart_tx),.RxD_data(byte_out),.RxD_data_ready(byte_ready));
    byte unsigned received[$];
    always @(posedge clk)if(byte_ready)received.push_back(byte_out);
    task automatic send_byte(input byte unsigned b);
        @(negedge clk);uart_rx=0;repeat(16)@(negedge clk);
        for(integer k=0;k<8;k=k+1)begin uart_rx=b[k];repeat(16)@(negedge clk);end
        uart_rx=1;repeat(32)@(negedge clk);
    endtask
    task automatic header(input byte unsigned len,input byte unsigned command);
        send_byte(8'haa);send_byte(0);send_byte(len);send_byte(command);
    endtask
    task automatic status(input [31:0] expected);
        integer from_byte;
        reg found;
        from_byte=received.size();header(1,8'h12);repeat(2500)@(negedge clk);
        found=0;
        for(integer k=from_byte;k+7<received.size();k=k+1)
            if(received[k]==8'haa&&received[k+1]==0&&received[k+2]==5&&received[k+3]==8'h12)begin
                if({received[k+4],received[k+5],received[k+6],received[k+7]}!==expected)
                    $fatal(1,"bad applied snapshot");
                found=1;
            end
        if(!found)$fatal(1,"status reply missing");
    endtask
    initial begin
        repeat(10)@(negedge clk);resetn=1;repeat(100)@(negedge clk);
        header(2,8'h08);send_byte(0);repeat(100)@(negedge clk);
        if(osd_input_block)$fatal(1,"input did not release");
        joy1=12'h144;#1;if(!osd_input_block)$fatal(1,"OSD2 chord leaked with extra A");
        repeat(4)@(negedge clk);joy1=0;repeat(5)@(negedge clk);
        if(osd_input_block)$fatal(1,"chord release stuck");
        joy2=12'h084;#1;if(osd_input_block)$fatal(1,"P2 claimed OSD ownership");
        // Keep a simultaneous joystick notification queued while a reply is requested.
        header(5,3);send_byte(0);send_byte(8'h1b);send_byte(8'h12);send_byte(8'h34);
        repeat(100)@(negedge clk);
        if(core_config!==32'h001b1234)$fatal(1,"UART config was not assembled");
        status(0); // no frame boundary, so no application yet
        @(negedge hclk);frame_start=1;@(negedge hclk);frame_start=0;
        repeat(12)@(negedge clk);status(32'h001b1234);
        header(6,3);send_byte(8'hde);send_byte(8'had);send_byte(8'hbe);send_byte(8'hef);send_byte(0);
        repeat(100)@(negedge clk);
        if(core_config!==32'h001b1234)$fatal(1,"wrong-length packet changed config");
        header(1,2);repeat(20000)@(negedge clk);
        begin
            string reply="";
            bit marker=0;
            for(integer k=0;k<received.size();k=k+1)begin
                reply={reply,received[k]};
                if(k>=6&&{received[k-6],received[k-5],received[k-4],received[k-3],received[k-2],received[k-1],received[k]}=="CRTSTG1")marker=1;
            end
            if(!marker)$fatal(1,"stage capability not transmitted");
        end
        $display("CRT UART PASS: real serial packets, frame-applied readback, packet length guard, capability, immediate chord blocking, P1 ownership");$finish;
    end
    initial begin #1000000;$fatal(1,"UART timeout");end
endmodule
