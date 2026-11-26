// Interrupt line, watched by dma_irq_monitor and the start sequence (wait-for-irq mode).
interface dma_irq_if (input logic clk, input logic rst_n);
    logic irq;
endinterface
