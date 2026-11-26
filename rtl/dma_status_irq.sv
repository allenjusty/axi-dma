// dma_status_irq: holds STATUS.DONE/ERR/ERR_CODE, pulses the INT_STATUS set inputs,
// and drives irq = |(INT_STATUS & INT_ENABLE) (spec rule 12).
module dma_status_irq (
    input  logic       clk,
    input  logic       rst_n,

    // Events from dma_ctrl
    input  logic       busy,
    input  logic       ev_start,
    input  logic       ev_done,
    input  logic       ev_err,
    input  logic [1:0] ev_err_code,

    // STATUS register value (to the register block)
    output logic       st_busy,
    output logic       st_done,
    output logic       st_err,
    output logic [1:0] st_err_code,

    // INT_STATUS hardware-set pulses (to the register block)
    output logic       int_set_done,
    output logic       int_set_err,

    // Register values (from the register block)
    input  logic [1:0] int_status,   // {ERR, DONE}
    input  logic [1:0] int_enable,   // {ERR, DONE}

    output logic       irq
);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st_done     <= 1'b0;
            st_err      <= 1'b0;
            st_err_code <= 2'd0;
        end else begin
            // A START clears the old result; a same-cycle DONE/ERR then overrides it.
            if (ev_start) begin
                st_done     <= 1'b0;
                st_err      <= 1'b0;
                st_err_code <= 2'd0;
            end
            if (ev_done) st_done <= 1'b1;
            if (ev_err) begin
                st_err      <= 1'b1;
                st_err_code <= ev_err_code;
            end
        end
    end

    assign st_busy      = busy;
    assign int_set_done = ev_done;
    assign int_set_err  = ev_err;
    assign irq          = |(int_status & int_enable);

endmodule
