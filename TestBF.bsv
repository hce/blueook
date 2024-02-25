import StmtFSM::*;

import BF::*;

(* synthesize *)
module mkTestBF(Empty);
   TM bf <- mkBF;
   
   let f <- mkReg(InvalidFile);
   
   Reg#(UInt#(4)) pos <- mkReg(0);
   
   rule file_open(pos == 0);
      File fh <- $fopen("gsit.ook", "r");
      f <= fh; pos <= 1;
   endrule
   
   rule file_read(f != InvalidFile && pos == 1);
      let c <- $fgetc(f);
      if (c == -1) begin
	 pos <= 2;
	 bf.startSimulate;
      end else bf.inp(truncate(pack(c)));
   endrule
   
   rule terminate (pos == 2 && !bf.simulationRunning);
      $finish;
   endrule
   
endmodule
   
   
