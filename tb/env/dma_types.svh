// Shared testbench types: environment config and the predicted transfer.

// Register offsets (spec register map)
localparam bit [11:0] REG_VERSION = 12'h00, REG_INT_STATUS = 12'h04, REG_INT_ENABLE = 12'h08,
                      REG_SRC = 12'h0C, REG_DST = 12'h10, REG_LEN = 12'h14,
                      REG_CTRL = 12'h18, REG_STATUS = 12'h1C;
localparam bit [31:0] VERSION_VALUE = 32'h0001_0000;

// ERR_CODE values
localparam int CODE_NONE = 0, CODE_CFG = 1, CODE_RD = 2, CODE_WR = 3;

// Why a burst was cut to its size (rule 6); ties go to the first in this order
typedef enum int {CUT_REMAIN = 0, CUT_MAXB = 1, CUT_SRC4K = 2, CUT_DST4K = 3} dma_cut_e;

// Config-error causes (coverage)
typedef enum int {CFG_UNALIGNED_SRC = 0, CFG_UNALIGNED_DST = 1, CFG_UNALIGNED_LEN = 2,
                  CFG_SRC_PAST_TOP = 3, CFG_DST_PAST_TOP = 4} dma_cfg_cause_e;

typedef struct {
    bit [31:0] src;
    bit [31:0] dst;
    int        beats;
    dma_cut_e  cut;
    bit        rd_err;      // some beat of this burst reads from an error range
    bit        wr_err;      // the B response for this burst is an error
} dma_burst_t;

// ------------------------------------------------------------------ environment config
class dma_env_cfg extends uvm_object;
    `uvm_object_utils(dma_env_cfg)
    axi_slave_cfg axi_cfg;
    axi_mem_model mem;
    int           clk_period_ns = 10;

    function new(string name = "dma_env_cfg");
        super.new(name);
        axi_cfg = axi_slave_cfg::type_id::create("axi_cfg");
        mem     = axi_mem_model::type_id::create("mem");
    endfunction
endclass

// ------------------------------------------------------------------ one predicted transfer
class dma_xfer extends uvm_object;
    `uvm_object_utils(dma_xfer)
    int         id;
    bit [31:0]  src, dst, len;
    bit [7:0]   max_burst;
    bit         cfg_err;
    bit [4:0]   cfg_causes;     // bit per dma_cfg_cause_e
    bit         zero_len;
    int         outcome;        // expected ERR_CODE (0 = DONE)
    int         n_planned;      // bursts the transfer would have without errors
    dma_burst_t bursts[$];      // bursts the DMA must issue, in order
    bit [31:0]  src_data[];     // source words at START time

    function new(string name = "dma_xfer");
        super.new(name);
    endfunction

    virtual function string convert2string();
        return $sformatf("xfer#%0d src=0x%08h dst=0x%08h len=%0d max_burst=%0d -> %0d bursts, %s",
                         id, src, dst, len, max_burst, bursts.size(),
                         cfg_err ? "CONFIG ERROR" : zero_len ? "ZERO LENGTH" :
                         outcome == CODE_RD ? "READ ERROR" : outcome == CODE_WR ? "WRITE ERROR" : "DONE");
    endfunction
endclass
