`timescale 1ns/1ps

module disp_selector_tb;

  // Parameters ------------------------------------------------------------
  localparam int RS_DEPTH       = 8;
  localparam int DISPATCH_WIDTH = 2;

  // DUT I/O ---------------------------------------------------------------
  logic [RS_DEPTH-1:0]                     empty_vec;
  logic [DISPATCH_WIDTH-1:0]               disp_valid_vec;
  logic [DISPATCH_WIDTH-1:0][RS_DEPTH-1:0] disp_grant_vec;

  // Instantiate DUT -------------------------------------------------------
  disp_selector #(
    .RS_DEPTH(RS_DEPTH),
    .DISPATCH_WIDTH(DISPATCH_WIDTH)
  ) dut (
    .empty_vec(empty_vec),
    .disp_valid_vec(disp_valid_vec),
    .disp_grant_vec(disp_grant_vec)
  );

  // -----------------------------------------------------------------------
  // Helper task to print and check results
  // -----------------------------------------------------------------------
  task automatic check_result(
    input string name,
    input int expected_grant_count
  );
    int count = 0;
    for (int i = 0; i < DISPATCH_WIDTH; i++)
      for (int j = 0; j < RS_DEPTH; j++)
        if (disp_grant_vec[i][j])
          count++;
    $display("[%0t] %s: grant count = %0d", $time, name, count);
    if (count != expected_grant_count)
      $error("%s: expected %0d grant(s), got %0d", name, expected_grant_count, count);
  endtask

  // -----------------------------------------------------------------------
  // Test sequence
  // -----------------------------------------------------------------------
  initial begin
    $display("=== disp_selector Test Start ===");

    // --------------------------------------------------
    // Test 1: Single dispatch, one empty slot
    // --------------------------------------------------
    empty_vec       = 8'b00000001; // only slot[0] empty
    disp_valid_vec  = 2'b01;       // only first dispatch active
    #1;
    check_result("Test1", 1);
    assert (disp_grant_vec[0][0] == 1'b1)
      else $error("Test1: expected grant at [0][0]");
    $display("disp_grant_vec=%b", disp_grant_vec);

    // --------------------------------------------------
    // Test 2: Dual dispatch, multiple empties
    // --------------------------------------------------
    empty_vec       = 8'b11110000; // slots [4:7] empty
    disp_valid_vec  = 2'b11;       // both dispatch slots valid
    #1;
    check_result("Test2", 2);
    assert (disp_grant_vec[0] != disp_grant_vec[1])
      else $error("Test2: duplicate grant!");
    $display("disp_grant_vec[0]=%b", disp_grant_vec[0]);
    $display("disp_grant_vec[1]=%b", disp_grant_vec[1]);

    // --------------------------------------------------
    // Test 3: No empty slot
    // --------------------------------------------------
    empty_vec       = 8'b00000000;
    disp_valid_vec  = 2'b11;
    #1;
    check_result("Test3", 0);
    $display("disp_grant_vec=%p", disp_grant_vec);

    // --------------------------------------------------
    // Test 4: Random stress test
    // --------------------------------------------------
    for (int t = 0; t < 5; t++) begin
      empty_vec      = $urandom_range(0, 255);
      disp_valid_vec = $urandom_range(0, 3);
      #1;
      $display("Random[%0d] empty=%b valid=%b grant=%p",
               t, empty_vec, disp_valid_vec, disp_grant_vec);
      // Basic property: never grant a slot that wasn't empty
      for (int i = 0; i < DISPATCH_WIDTH; i++)
        for (int j = 0; j < RS_DEPTH; j++)
          if (disp_grant_vec[i][j])
            assert (empty_vec[j])
              else $error("Random[%0d]: granted non-empty slot %0d!", t, j);
    end

    $display("=== disp_selector Test Complete ===");
    $finish;
  end
endmodule
