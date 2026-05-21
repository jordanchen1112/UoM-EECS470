`ifndef __DEF_SVH__
`define __DEF_SVH__

// =========================================================
// Global architectural configuration parameters
// =========================================================


`ifndef __DEF_SVH__
`define __DEF_SVH__


/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  sys_defs.svh                                        //
//                                                                     //
//  Description :  This file defines macros and data structures used   //
//                 throughout the processor.                           //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

// all files should `include "sys_defs.svh" to at least define the timescale
`timescale 1ns/100ps

///////////////////////////////
// ---- Basic Constants ---- //
///////////////////////////////

// NOTE: the global CLOCK_PERIOD is defined in the Makefile

// useful boolean single-bit definitions


// superscalar width, the max number of instructions that can commit at once



// the zero register
// In RISC-V, any read of this register returns zero and any writes are thrown away
// `define ZERO_REG 5'd0

// Basic NOP instruction. Allows pipline registers to clearly be reset with
// an instruction that does nothing instead of Zero which is really an ADDI x0, x0, 0
// `define NOP 32'h00000013

//////////////////////////////////
// ---- Memory Definitions ---- //
//////////////////////////////////

// this will change for project 4
// the project 3 processor has a massive boost in performance just from having no mem latency
// see if you can beat it's CPI in project 4 even with a 100ns latency!
// `define MEM_LATENCY_IN_CYCLES  0

// // memory tags represent a unique id for outstanding mem transactions
// // 0 is a sentinel value and is not a valid tag
// `define NUM_MEM_TAGS 15
// typedef logic [3:0] MEM_TAG;

// `define MEM_SIZE_IN_BYTES (64*1024)
// `define MEM_64BIT_LINES   (`MEM_SIZE_IN_BYTES/8)

// A memory or cache block
// typedef union packed {
//     logic [7:0][7:0]  byte_level;
//     logic [3:0][15:0] half_level;
//     logic [1:0][31:0] word_level;
//     logic      [63:0] dbbl_level;
// } MEM_BLOCK;

// typedef enum logic [1:0] {
//     BYTE   = 2'h0,
//     HALF   = 2'h1,
//     WORD   = 2'h2,
//     DOUBLE = 2'h3
// } MEM_SIZE;

// // Memory bus commands
// typedef enum logic [1:0] {
//     MEM_NONE   = 2'h0,
//     MEM_LOAD   = 2'h1,
//     MEM_STORE  = 2'h2
// } MEM_COMMAND;

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

// typedef enum logic [3:0] {
//     INST_ADDR_MISALIGN  = 4'h0,
//     INST_ACCESS_FAULT   = 4'h1,
//     ILLEGAL_INST        = 4'h2,
//     BREAKPOINT          = 4'h3,
//     LOAD_ADDR_MISALIGN  = 4'h4,
//     LOAD_ACCESS_FAULT   = 4'h5,
//     STORE_ADDR_MISALIGN = 4'h6,
//     STORE_ACCESS_FAULT  = 4'h7,
//     ECALL_U_MODE        = 4'h8,
//     ECALL_S_MODE        = 4'h9,
//     NO_ERROR            = 4'ha, // a reserved code that we use to signal no errors
//     ECALL_M_MODE        = 4'hb,
//     INST_PAGE_FAULT     = 4'hc,
//     LOAD_PAGE_FAULT     = 4'hd,
//     HALTED_ON_WFI       = 4'he, // 'Wait For Interrupt'. In 470, signifies the end of computation
//     STORE_PAGE_FAULT    = 4'hf
// } EXCEPTION_CODE;

////////////////////////////////////////
// ---- Datapath Control Signals ---- //
////////////////////////////////////////

// ALU opA input mux selects
// typedef enum logic [1:0] {
//     OPA_IS_RS1,
//     OPA_IS_NPC,
//     OPA_IS_PC,
//     OPA_IS_ZERO
// } ALU_OPA_SELECT;



// Which ALU operation to perform
// typedef enum logic [3:0] {
//     ALU_ADD,
//     ALU_SUB,
//     ALU_SLT,
//     ALU_SLTU,
//     ALU_AND,
//     ALU_OR,
//     ALU_XOR,
//     ALU_SLL,
//     ALU_SRL,
//     ALU_SRA
// } ALU_FUNC;

// Mult extension operations
// These map to the RISC-V M-extension funct3 bits
// We don't implement any of the DIV or REM operations
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



// from the RISC-V ISA spec
// typedef union packed {
//     logic [31:0] inst;
//     struct packed {
//         logic [6:0] funct7;
//         logic [4:0] rs2; // source register 2
//         logic [4:0] rs1; // source register 1
//         logic [2:0] funct3;
//         logic [4:0] rd; // destination register
//         logic [6:0] opcode;
//     } r; // register-to-register instructions
//     struct packed {
//         logic [11:0] imm; // immediate value for calculating address
//         logic [4:0]  rs1; // source register 1 (used as address base)
//         logic [2:0]  funct3;
//         logic [4:0]  rd;  // destination register
//         logic [6:0]  opcode;
//     } i; // immediate or load instructions
//     struct packed {
//         logic [6:0] off; // offset[11:5] for calculating address
//         logic [4:0] rs2; // source register 2
//         logic [4:0] rs1; // source register 1 (used as address base)
//         logic [2:0] funct3;
//         logic [4:0] set; // offset[4:0] for calculating address
//         logic [6:0] opcode;
//     } s; // store instructions
//     struct packed {
//         logic       of;  // offset[12]
//         logic [5:0] s;   // offset[10:5]
//         logic [4:0] rs2; // source register 2
//         logic [4:0] rs1; // source register 1
//         logic [2:0] funct3;
//         logic [3:0] et;  // offset[4:1]
//         logic       f;   // offset[11]
//         logic [6:0] opcode;
//     } b; // branch instructions
//     struct packed {
//         logic [19:0] imm; // immediate value
//         logic [4:0]  rd; // destination register
//         logic [6:0]  opcode;
//     } u; // upper-immediate instructions
//     struct packed {
//         logic       of; // offset[20]
//         logic [9:0] et; // offset[10:1]
//         logic       s;  // offset[11]
//         logic [7:0] f;  // offset[19:12]
//         logic [4:0] rd; // destination register
//         logic [6:0] opcode;
//     } j;  // jump instructions

// // extensions for other instruction types
// `ifdef ATOMIC_EXT
//     struct packed {
//         logic [4:0] funct5;
//         logic       aq;
//         logic       rl;
//         logic [4:0] rs2;
//         logic [4:0] rs1;
//         logic [2:0] funct3;
//         logic [4:0] rd;
//         logic [6:0] opcode;
//     } a; // atomic instructions
// `endif
// `ifdef SYSTEM_EXT
//     struct packed {
//         logic [11:0] csr;
//         logic [4:0]  rs1;
//         logic [2:0]  funct3;
//         logic [4:0]  rd;
//         logic [6:0]  opcode;
//     } sys; // system call instructions
// `endif

// } INST; // instruction typedef, this should cover all types of instructions



`endif // __DEF_SVH__


`endif // __SYS_DEFS_SVH__
