// DMA verification environment: config, reference model, scoreboard, irq monitor, coverage.
package dma_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import apb_pkg::*;
    import axi_pkg::*;
    import dma_regs_ral_pkg::*;

    `include "dma_types.svh"
    `include "dma_coverage.svh"
    `include "dma_ref_model.svh"
    `include "dma_scoreboard.svh"
    `include "dma_env.svh"
endpackage
