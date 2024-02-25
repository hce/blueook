import BRAM::*;
import FIFO::*;
import Vector::*;

interface TM;
   method Action inp(Bit#(8) b);
   method Action startSimulate;
   method Bool simulationRunning;
endinterface

typedef enum { BFInc, BFDec, BFLeft, BFRight,
	      BFLoopBegin, BFLoopEnd, BFPrint, BFInput
	      } Instruction deriving (Bits, Eq);

typedef enum { OokDot, OokExclamationMark, OokQuestionMark
	      } Ooky deriving (Bits, Eq);

(* synthesize *)
module mkBF(TM);
   Reg#(Bool) simulationActive <- mkReg(False);
   Reg#(Bool) nextInstruction <- mkReg(True);
   
   // Program/instruction counter
   Reg#(UInt#(16)) ip[2] <- mkCReg(2, 0);
   Reg#(UInt#(16)) programSize <- mkRegU;
   
   // Data counter
   Reg#(UInt#(20)) dc <- mkReg(0);
   
   // Used for reading in a new program
   Reg#(Maybe#(Ooky)) leftOok <- mkReg(tagged Invalid);

   // Any instruction pending RAM, ALU or other operations
   Reg#(Maybe#(Instruction)) currInstruction <- mkReg(tagged Invalid);
   
   Reg#(UInt#(2)) ookPos <- mkReg(0);
   
   FIFO#(Bit#(8)) inputFifo <- mkFIFO;
   
   BRAM_Configure cfgCS = defaultValue;
   cfgCS.memorySize = 64 * 1024;
   BRAM2Port#(UInt#(16), Instruction) cs <- mkBRAM2Server(cfgCS);
   
   BRAM_Configure cfgDS = defaultValue;
   cfgDS.memorySize = 1024 * 1024;
   BRAM2Port#(UInt#(20), Int#(8)) ds <- mkBRAM2Server(cfgDS);
   Reg#(UInt#(21)) dsRamFillerPos <- mkReg(0);
   
   Vector#(64, Reg#(UInt#(16))) stack <- replicateM(mkRegU);
   Reg#(UInt#(7)) sp <- mkReg(0);
   
   Reg#(UInt#(16)) skipLoop <- mkReg(0);
   
   rule dsRamFiller (!simulationActive && dsRamFillerPos < 1024*1024);
      BRAMRequest#(UInt#(20), Int#(8)) wreq = defaultValue;
      wreq.write = True;
      wreq.responseOnWrite = False;
      wreq.address = truncate(dsRamFillerPos);
      wreq.datain = 0;
      ds.portA.request.put(wreq);
      dsRamFillerPos <= dsRamFillerPos + 1;
   endrule
      
   rule processInput (!simulationActive);
      let b = inputFifo.first; inputFifo.deq;
      if (ookPos == 0 && b == 79 /* O */) ookPos <= 1;
      else if (ookPos == 1 && b == 111 /* o */) ookPos <= 2;
      else if (ookPos == 2 && b == 107 /* k */) ookPos <= 3;
      else if (ookPos == 3) begin
	 let ookChar = tagged Invalid;
	 if (b == 46) ookChar = tagged Valid OokDot;
	 else if (b == 33) ookChar = tagged Valid OokExclamationMark;
	 else if (b == 63) ookChar = tagged Valid OokQuestionMark;
	 
	 if (!isValid(leftOok))
	    leftOok <= ookChar;
	 else begin
	    if (leftOok matches tagged Valid .l &&& ookChar matches tagged Valid .r) begin
	       let instr = tagged Invalid;
	       if      (l == OokDot && r == OokDot)                         instr = tagged Valid BFInc;
	       else if (l == OokExclamationMark && r == OokExclamationMark) instr = tagged Valid BFDec;
	       else if (l == OokDot && r == OokQuestionMark)                instr = tagged Valid BFRight;
	       else if (l == OokQuestionMark && r == OokDot)                instr = tagged Valid BFLeft;
	       else if (l == OokExclamationMark && r == OokQuestionMark)    instr = tagged Valid BFLoopBegin;
	       else if (l == OokQuestionMark && r == OokExclamationMark)    instr = tagged Valid BFLoopEnd;
	       else if (l == OokExclamationMark && r == OokDot)             instr = tagged Valid BFPrint;
	       else if (l == OokDot && r == OokExclamationMark)             instr = tagged Valid BFInput;
	       if (instr matches tagged Valid .i) begin
		  BRAMRequest#(UInt#(16), Instruction) r = BRAMRequest {
		     write: True,
		     responseOnWrite: False,
		     address: ip[0],
		     datain: i };
		  cs.portA.request.put(r);
		  ip[0] <= ip[0] + 1;
	       end
	    end
	    leftOok <= tagged Invalid;
	 end
	 ookPos <= 0;
      end
   endrule
   
   rule finish (simulationActive && nextInstruction && ip[0] >= programSize);
      simulationActive <= False;
      ip[0] <= 0;
      programSize <= 0;
   endrule
   
   rule simulate (simulationActive && nextInstruction && ip[0] < programSize);
      BRAMRequest#(UInt#(16), Instruction) r = BRAMRequest {
	 write: False,
	 responseOnWrite: False,
	 address: ip[0],
	 datain: BFInc };
      cs.portA.request.put(r);
      nextInstruction <= False;
   endrule
   
   rule handleInstruction (simulationActive && !nextInstruction && currInstruction == tagged Invalid);
      let r <- cs.portA.response.get;
      BRAMRequest#(UInt#(20), Int#(8)) rreq = defaultValue;
      rreq.write = False; rreq.address = dc;
      case (r) matches
	 BFInc       : begin
			  ip[0] <= ip[0] + 1;
			  ds.portA.request.put(rreq);
			  currInstruction <= tagged Valid BFInc;
			  end
	 BFDec       : begin
			  ip[0] <= ip[0] + 1;
			  ds.portA.request.put(rreq);
			  currInstruction <= tagged Valid BFDec;
			  end
	 BFLeft      : begin ip[0] <= ip[0] + 1; dc <= dc - 1; nextInstruction <= True; end
	 BFRight     : begin ip[0] <= ip[0] + 1; dc <= dc + 1; nextInstruction <= True; end
	 BFLoopBegin : begin
			  ds.portA.request.put(rreq);
			  currInstruction <= tagged Valid BFLoopBegin;
		       end
	 BFLoopEnd   : begin
			  ip[0] <= stack[sp - 1];
			  nextInstruction <= True;
			  sp <= sp - 1;
		       end
	 BFPrint     : begin
			  ip[0] <= ip[0] + 1;
			  ds.portA.request.put(rreq);
			  currInstruction <= tagged Valid BFPrint;	  
		       end
	 BFInput     : begin
			  ip[0] <= ip[0] + 1;
			  currInstruction <= tagged Valid BFInput;
		       end
      endcase
   endrule
   
   rule handleInc (simulationActive && currInstruction == tagged Valid BFInc && !nextInstruction);
      let currValue <- ds.portA.response.get;
      let newValue = currValue + 1;
      BRAMRequest#(UInt#(20), Int#(8)) wreq = defaultValue;
      wreq.write = True;
      wreq.responseOnWrite = False;
      wreq.address = dc;
      wreq.datain = newValue;
      ds.portA.request.put(wreq);
      currInstruction <= tagged Invalid;
      nextInstruction <= True;
   endrule

   rule handleDec (simulationActive && currInstruction == tagged Valid BFDec && !nextInstruction);
      let currValue <- ds.portA.response.get;
      let newValue = currValue - 1;
      BRAMRequest#(UInt#(20), Int#(8)) wreq = defaultValue;
      wreq.write = True;
      wreq.responseOnWrite = False;
      wreq.address = dc;
      wreq.datain = newValue;
      ds.portA.request.put(wreq);
      currInstruction <= tagged Invalid;
      nextInstruction <= True;
   endrule
   
   rule handlePrint (simulationActive && currInstruction == tagged Valid BFPrint && !nextInstruction);
      let currValue <- ds.portA.response.get;
      $write("%c", currValue);
      $fflush(stdout);
      currInstruction <= tagged Invalid;
      nextInstruction <= True;
   endrule   
   
   
   rule handleInput (simulationActive && currInstruction == tagged Valid BFInput && !nextInstruction);
      let newValue <- $fgetc(stdin);
      
      BRAMRequest#(UInt#(20), Int#(8)) wreq = defaultValue;
      wreq.write = True;
      wreq.responseOnWrite = False;
      wreq.address = dc;
      wreq.datain = truncate(newValue);
      ds.portA.request.put(wreq);
      
      currInstruction <= tagged Invalid;
      nextInstruction <= True;
   endrule

   rule handleLoopBegin (simulationActive && currInstruction == tagged Valid BFLoopBegin && !nextInstruction && skipLoop == 0);
      let currValue <- ds.portA.response.get;
      if (currValue != 0) begin
	 stack[sp] <= ip[0];
	 sp <= sp + 1;
	 // Go fetch the next statement
	 currInstruction <= tagged Invalid;
      end else skipLoop <= 1;
      // Move past the beginning of the loop
      ip[0] <= ip[0] + 1;
      nextInstruction <= True;	 
   endrule
   
   rule do_skip_loop (simulationActive && currInstruction == tagged Valid BFLoopBegin && !nextInstruction && skipLoop > 0);
      let instr <- cs.portA.response.get;
      ip[0] <= ip[0] + 1;
      if (instr == BFLoopBegin) skipLoop <= skipLoop + 1;
      else if (instr == BFLoopEnd) begin
	 let newLoopDepth = skipLoop - 1;
	 skipLoop <= newLoopDepth;
	 if (newLoopDepth == 0) currInstruction <= tagged Invalid;
      end
      nextInstruction <= True;
   endrule
   
   method Action inp(Bit#(8) b) if (!simulationActive);
      inputFifo.enq(b);
   endmethod
   
   method Action startSimulate if (!simulationActive);
      programSize <= ip[1];
      ip[1] <= 0;
      simulationActive <= True;
   endmethod
   
   method Bool simulationRunning;
      return simulationActive;
   endmethod: simulationRunning
endmodule
