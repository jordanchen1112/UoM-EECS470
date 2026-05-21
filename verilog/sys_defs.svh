/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  sys_defs.svh                                        //
//                                                                     //
//  Description :  This file defines macros and data structures used   //
//                 throughout the processor.                           //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`ifndef __SYS_DEFS_SVH__
`define __SYS_DEFS_SVH__

// all files should `include "sys_defs.svh" to at least define the timescale
`timescale 1ns/100ps

///////////////////////////////////
// ---- Starting Parameters ---- //
///////////////////////////////////

// some starting parameters that you should set
// this is *your* processor, you decide these values (try analyzing which is best!)

// superscalar width
`define N 1
`define SINGLE_FU_NUM 1
`define RS_DEPTH 16
`define ROB_DEPTH 32
`define MULT_STAGES 2

`define SQ_SIZE 16
`define LQ_SIZE 16
`define LQ_IDX_WIDTH $clog2(`SQ_SIZE) 
`define SQ_IDX_WIDTH $clog2(`LQ_SIZE)

// fixed data
`define FU_ALU `SINGLE_FU_NUM
`define FU_MUL `SINGLE_FU_NUM
`define FU_LOAD `SINGLE_FU_NUM
`define FU_BRANCH `SINGLE_FU_NUM
`define ALU_COUNT `FU_ALU
`define MUL_COUNT `FU_MUL
`define LOAD_COUNT `FU_LOAD
`define BR_COUNT `FU_BRANCH
`define FU_NUM (`ALU_COUNT + `MUL_COUNT + `LOAD_COUNT + `BR_COUNT)
`define CDB_WIDTH `FU_NUM
`define WB_WIDTH `FU_NUM
`define READ_PORTS (2 * `FU_NUM)
`define DISPATCH_WIDTH `N
`define COMMIT_WIDTH `N
`define FETCH_WIDTH `N
`define ISSUE_WIDTH `N
`define CDB_SZ `N
`define INST_W 16
`define ADDR_WIDTH 32
`define PHYS_REGS 64
`define ARCH_REGS 32
`define XLEN 32
`define OPCODE_N 7

// number of mult stages (2, 4) (you likely don't need 8)


///////////////////////////////
// ---- Basic Constants ---- //
///////////////////////////////

// NOTE: the global CLOCK_PERIOD is defined in the Makefile

// useful boolean single-bit definitions
`define FALSE 1'h0
`define TRUE  1'h1

// word and register sizes
typedef logic [31:0] ADDR;
typedef logic [31:0] DATA;
typedef logic [4:0] REG_IDX;
typedef logic [$clog2(`ROB_DEPTH)-1:0] ROB_IDX;
// the zero register
// In RISC-V, any read of this register returns zero and any writes are thrown away
`define ZERO_REG 5'd0

// Basic NOP instruction. Allows pipline registers to clearly be reset with
// an instruction that does nothing instead of Zero which is really an ADDI x0, x0, 0
`define NOP 32'h00000013

//////////////////////////////////
// ---- Memory Definitions ---- //
//////////////////////////////////

// you are not allowed to change this definition for your final processor
// the project 3 processor has a massive boost in performance just from having no mem latency
// see if you can beat it's CPI in project 4 even with a 100ns latency!
`define MEM_LATENCY_IN_CYCLES  2
// `define MEM_LATENCY_IN_CYCLES (100.0/`CLOCK_PERIOD+0.49999)
// the 0.49999 is to force ceiling(100/period). The default behavior for
// float to integer conversion is rounding to nearest
`define CACHE_MODE 1
// memory tags represent a unique id for outstanding mem transactions
// 0 is a sentinel value and is not a valid tag
`define NUM_MEM_TAGS 15
typedef logic [3:0] MEM_TAG;

// icache definitions
`define ICACHE_LINES 32
`define ICACHE_LINE_BITS $clog2(`ICACHE_LINES)

`define MEM_SIZE_IN_BYTES (64*1024)
`define MEM_64BIT_LINES   (`MEM_SIZE_IN_BYTES/8)

// A memory or cache block
typedef union packed {
    logic [7:0][7:0]  byte_level;
    logic [3:0][15:0] half_level;
    logic [1:0][31:0] word_level;
    logic      [63:0] dbbl_level;
} MEM_BLOCK;

typedef enum logic [1:0] {
    BYTE   = 2'h0,
    HALF   = 2'h1,
    WORD   = 2'h2,
    DOUBLE = 2'h3
} MEM_SIZE;

// Memory bus commands
typedef enum logic [1:0] {
    MEM_NONE   = 2'h0,
    MEM_LOAD   = 2'h1,
    MEM_STORE  = 2'h2
} MEM_COMMAND;

// icache tag struct
typedef struct packed {
    logic [12-`ICACHE_LINE_BITS:0] tags;
    logic                          valid;
} ICACHE_TAG;

///////////////////////////////
// ---- Exception Codes ---- //
///////////////////////////////

/**
 * Exception codes for when something goes wrong in the processor.
 * Note that we use HALTED_ON_WFI to signify the end of computation.
 * It's original meaning is to 'Wait For an Interrupt', but we generally
 * ignore interrupts in 470
 *
 * This mostly follows the RISC-V Privileged spec
 * except a few add-ons for our infrastructure
 * The majority of them won't be used, but it's good to know what they are
 */

typedef enum logic [3:0] {
    INST_ADDR_MISALIGN  = 4'h0,
    INST_ACCESS_FAULT   = 4'h1,
    ILLEGAL_INST        = 4'h2,
    BREAKPOINT          = 4'h3,
    LOAD_ADDR_MISALIGN  = 4'h4,
    LOAD_ACCESS_FAULT   = 4'h5,
    STORE_ADDR_MISALIGN = 4'h6,
    STORE_ACCESS_FAULT  = 4'h7,
    ECALL_U_MODE        = 4'h8,
    ECALL_S_MODE        = 4'h9,
    NO_ERROR            = 4'ha, // a reserved code that we use to signal no errors
    ECALL_M_MODE        = 4'hb,
    INST_PAGE_FAULT     = 4'hc,
    LOAD_PAGE_FAULT     = 4'hd,
    HALTED_ON_WFI       = 4'he, // 'Wait For Interrupt'. In 470, signifies the end of computation
    STORE_PAGE_FAULT    = 4'hf
} EXCEPTION_CODE;

///////////////////////////////////
// ---- Instruction Typedef ---- //
///////////////////////////////////

// from the RISC-V ISA spec
typedef union packed {
    logic [31:0] inst;
    struct packed {
        logic [6:0] funct7;
        logic [4:0] rs2; // source register 2
        logic [4:0] rs1; // source register 1
        logic [2:0] funct3;
        logic [4:0] rd; // destination register
        logic [6:0] opcode;
    } r; // register-to-register instructions
    struct packed {
        logic [11:0] imm; // immediate value for calculating address
        logic [4:0]  rs1; // source register 1 (used as address base)
        logic [2:0]  funct3;
        logic [4:0]  rd;  // destination register
        logic [6:0]  opcode;
    } i; // immediate or load instructions
    struct packed {
        logic [6:0] off; // offset[11:5] for calculating address
        logic [4:0] rs2; // source register 2
        logic [4:0] rs1; // source register 1 (used as address base)
        logic [2:0] funct3;
        logic [4:0] set; // offset[4:0] for calculating address
        logic [6:0] opcode;
    } s; // store instructions
    struct packed {
        logic       of;  // offset[12]
        logic [5:0] s;   // offset[10:5]
        logic [4:0] rs2; // source register 2
        logic [4:0] rs1; // source register 1
        logic [2:0] funct3;
        logic [3:0] et;  // offset[4:1]
        logic       f;   // offset[11]
        logic [6:0] opcode;
    } b; // branch instructions
    struct packed {
        logic [19:0] imm; // immediate value
        logic [4:0]  rd; // destination register
        logic [6:0]  opcode;
    } u; // upper-immediate instructions
    struct packed {
        logic       of; // offset[20]
        logic [9:0] et; // offset[10:1]
        logic       s;  // offset[11]
        logic [7:0] f;  // offset[19:12]
        logic [4:0] rd; // destination register
        logic [6:0] opcode;
    } j;  // jump instructions

// extensions for other instruction types
`ifdef ATOMIC_EXT
    struct packed {
        logic [4:0] funct5;
        logic       aq;
        logic       rl;
        logic [4:0] rs2;
        logic [4:0] rs1;
        logic [2:0] funct3;
        logic [4:0] rd;
        logic [6:0] opcode;
    } a; // atomic instructions
`endif
`ifdef SYSTEM_EXT
    struct packed {
        logic [11:0] csr;
        logic [4:0]  rs1;
        logic [2:0]  funct3;
        logic [4:0]  rd;
        logic [6:0]  opcode;
    } sys; // system call instructions
`endif

} INST; // instruction typedef, this should cover all types of instructions

////////////////////////////////////////
// ---- Datapath Control Signals ---- //
////////////////////////////////////////

// ALU opA input mux selects
typedef enum logic [1:0] {
    OPA_IS_RS1  = 2'h0,
    OPA_IS_NPC  = 2'h1,
    OPA_IS_PC   = 2'h2,
    OPA_IS_ZERO = 2'h3
} ALU_OPA_SELECT;

// ALU opB input mux selects
typedef enum logic [2:0] {
    OPB_IS_RS2    = 3'h0,
    OPB_IS_I_IMM  = 3'h1,
    OPB_IS_S_IMM  = 3'h2,
    OPB_IS_B_IMM  = 3'h3,
    OPB_IS_U_IMM  = 3'h4,
    OPB_IS_J_IMM  = 3'h5
} ALU_OPB_SELECT;

// ALU function code
typedef enum logic [3:0] {
    ALU_ADD     = 4'h0,
    ALU_SUB     = 4'h1,
    ALU_SLT     = 4'h2,
    ALU_SLTU    = 4'h3,
    ALU_AND     = 4'h4,
    ALU_OR      = 4'h5,
    ALU_XOR     = 4'h6,
    ALU_SLL     = 4'h7,
    ALU_SRL     = 4'h8,
    ALU_SRA     = 4'h9
} ALU_FUNC;

// MULT funct3 code
// we don't include division or rem options
typedef enum logic [2:0] {
    M_MUL,
    M_MULH,
    M_MULHSU,
    M_MULHU
} MULT_FUNC;

function automatic logic is_older(ROB_IDX a, ROB_IDX b, ROB_IDX head);
    int dist_a, dist_b;
    
    if (a >= head) dist_a = a - head;
    else           dist_a = (a + `ROB_DEPTH) - head;

    if (b >= head) dist_b = b - head;
    else           dist_b = (b + `ROB_DEPTH) - head;

    return (dist_a < dist_b);
endfunction

// typedef enum logic [2:0] {
//     M_MUL     = 3'b000,
//     M_MULH    = 3'b001,
//     M_MULHSU  = 3'b010,
//     M_MULHU   = 3'b011,
//     M_DIV     = 3'b100,
//     M_DIVU    = 3'b101,
//     M_REM     = 3'b110,
//     M_REMU    = 3'b111
// } MULT_FUNC3;

////////////////////////////////
// ---- Datapath Packets ---- //
////////////////////////////////

/**
 * Packets are used to move many variables between modules with
 * just one datatype, but can be cumbersome in some circumstances.
 *
 * Define new ones in project 4 at your own discretion
 */

/**
 * IF_ID Packet:
 * Data exchanged from the IF to the ID stage
 */
typedef struct packed {
    INST  inst;
    ADDR  PC;
    ADDR  NPC; // PC + 4
    logic valid;
} IF_ID_PACKET;

/**
 * ID_EX Packet:
 * Data exchanged from the ID to the EX stage
 */
typedef struct packed {
    INST inst;
    ADDR PC;
    ADDR NPC; // PC + 4

    DATA rs1_value; // reg A value
    DATA rs2_value; // reg B value

    ALU_OPA_SELECT opa_select; // ALU opa mux select (ALU_OPA_xxx *)
    ALU_OPB_SELECT opb_select; // ALU opb mux select (ALU_OPB_xxx *)

    REG_IDX  dest_reg_idx;  // destination (writeback) register index
    ALU_FUNC alu_func;      // ALU function select (ALU_xxx *)
    logic    mult;          // Is inst a multiply instruction?
    logic    rd_mem;        // Does inst read memory?
    logic    wr_mem;        // Does inst write memory?
    logic    cond_branch;   // Is inst a conditional branch?
    logic    uncond_branch; // Is inst an unconditional branch?
    logic    halt;          // Is this a halt?
    logic    illegal;       // Is this instruction illegal?
    logic    csr_op;        // Is this a CSR operation? (we only used this as a cheap way to get return code)

    logic    valid;
} ID_EX_PACKET;

/**
 * EX_MEM Packet:
 * Data exchanged from the EX to the MEM stage
 */
typedef struct packed {
    DATA alu_result;
    ADDR NPC;

    logic    take_branch; // Is this a taken branch?
    // Pass-through from decode stage
    DATA     rs2_value;
    logic    rd_mem;
    logic    wr_mem;
    REG_IDX  dest_reg_idx;
    logic    halt;
    logic    illegal;
    logic    csr_op;
    logic    rd_unsigned; // Whether proc2Dmem_data is signed or unsigned
    MEM_SIZE mem_size;
    logic    valid;
} EX_MEM_PACKET;

/**
 * MEM_WB Packet:
 * Data exchanged from the MEM to the WB stage
 *
 * Does not include data sent from the MEM stage to memory
 */
typedef struct packed {
    DATA    result;
    ADDR    NPC;
    REG_IDX dest_reg_idx; // writeback destination (ZERO_REG if no writeback)
    logic   take_branch;
    logic   halt;    // not used by wb stage
    logic   illegal; // not used by wb stage
    logic   valid;
} MEM_WB_PACKET;

/**
 * Commit Packet:
 * This is an output of the processor and used in the testbench for counting
 * committed instructions
 *
 * It also acts as a "WB_PACKET", and can be reused in the final project with
 * some slight changes
 */
typedef struct packed {
    ADDR    NPC;
    DATA    data;
    REG_IDX reg_idx;
    logic   halt;
    logic   illegal;
    logic   valid;
} COMMIT_PACKET;



typedef struct packed {
    INST inst; //INST.i.imm
    ADDR PC;
    ADDR NPC; // PC + 4

    //DATA rs1_value; // reg A value
    //DATA rs2_value; // reg B value

    ALU_OPA_SELECT opa_select; // ALU opa mux select (ALU_OPA_xxx *)
    ALU_OPB_SELECT opb_select; // ALU opb mux select (ALU_OPB_xxx *)

    REG_IDX  dest_reg_idx;  // destination (writeback) register index
    ALU_FUNC alu_func;      // ALU function select (ALU_xxx *)
    logic    mult;          // Is inst a multiply instruction?
    logic    rd_mem;        // Does inst read memory?
    logic    wr_mem;        // Does inst write memory?
    logic    cond_branch;   // Is inst a conditional branch?
    logic    uncond_branch; // Is inst an unconditional branch?
    logic    halt;          // Is this a halt?
    logic    illegal;       // Is this instruction illegal?
    logic    csr_op;        // Is this a CSR operation? (we only used this as a cheap way to get return code)
    logic    [1:0]fu_type;

    logic    valid;
} DISP_PACKET;

typedef struct packed {
    logic                           valid;     // = busy
    logic [$clog2(`ROB_DEPTH)-1:0]  rob_idx;
    logic [1:0]                     fu_type; 
    logic [$clog2(`ARCH_REGS)-1:0]  dest_arch_reg; // for cdb update map table
    logic [$clog2(`PHYS_REGS)-1:0]  dest_tag;  // write reg
    logic [$clog2(`PHYS_REGS)-1:0]  src1_tag;  // source reg 1      
    logic [$clog2(`PHYS_REGS)-1:0]  src2_tag;  // source reg 2
    logic                          src1_ready; // is value of source reg 1 ready?
    logic                          src2_ready; // is value of source reg 2 ready?
    
    DISP_PACKET                   disp_packet; //decoder_o 
} rs_entry_t;

typedef enum logic [1:0] {
    FU_ALU = 2'b00,
    FU_MUL = 2'b01,
    FU_LOAD = 2'b10,
    FU_BRANCH = 2'b11
} fu_type_e;



typedef struct packed {
    logic                          valid;
    logic [`XLEN-1:0]              value;
    logic [$clog2(`PHYS_REGS)-1:0] dest_prf;
    logic [`XLEN-1:0] sw_data;
    logic                          is_lw;
    logic                          is_sw;
    logic [$clog2(`ROB_DEPTH)-1:0] rob_idx;
    logic                          exception;
    logic                          mispred;
    ADDR                           j_type_value;
    logic                          is_jtype;
    logic [2:0]                    funct3;
} fu_resp_t;

typedef struct packed {
    logic                         valid;      // broadcast valid
    logic [$clog2(`ARCH_REGS)-1:0] dest_arch;  // Arch reg
    logic [$clog2(`PHYS_REGS)-1:0] phys_tag;   // PRF tag
    logic [`XLEN-1:0]              value;      // result value
} cdb_entry_t;

typedef struct packed {
    logic [$clog2(`PHYS_REGS)-1:0] phys;  // physical register tag
    logic                         valid; // 1 = physical register holds valid data
} map_entry_t;





typedef struct packed {
    logic     valid;
    ADDR      addr;
    logic     addr_valid; //### sychenn
    MEM_SIZE  size;
    ROB_IDX   rob_idx;
    logic     data_valid;
    MEM_BLOCK data;
    logic     issued;  //whether request was sent to dcache
    logic [$clog2(`PHYS_REGS)-1:0]disp_rd_new_prf;
    logic [2:0] funct3;
} lq_entry_t;


typedef struct packed {
    logic     valid;
    ADDR      addr;
    logic     addr_valid;
    MEM_SIZE  size;
    ROB_IDX   rob_idx;
    logic     data_valid;
    MEM_BLOCK data;
    logic     commited; 
} sq_entry_t; // marked by ROB commited

typedef struct packed {
    logic                          valid;    
    fu_type_e                      fu_type;       // functional unit type
    logic [3:0]                    opcode;        // operation code
    logic [$clog2(`PHYS_REGS)-1:0] dest_tag;      // destination physical reg tag
    logic [`XLEN-1:0]               src1_mux;
    logic [`XLEN-1:0]               src2_mux;
    logic                          src1_valid;      // if src1_valid = 1 用rs1 ;  if src1_valid = 0 用imm
    // logic [`XLEN-1:0]               src1_val;
    logic [`XLEN-1:0]               src1_val;      // actual operand value 1
    logic [`XLEN-1:0]               src2_val;      // actual operand value 2
    logic                           src2_valid;      // if src2_valid = 1 用rs2 ;  if src2_valid = 0 用imm
    logic [`XLEN-1:0]               imm;
    logic [$clog2(`ROB_DEPTH)-1:0] rob_idx;       // reorder buffer index
    DISP_PACKET                    disp_packet; //decoder_o 
    // logic [2:0]                    funct3;
} issue_packet_t;
`endif // __SYS_DEFS_SVH__

