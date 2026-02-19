-- Cross-language benchmark: Ada — Ordered_Maps (red-black tree) vs FAST FFI.
--
-- Ada.Containers.Ordered_Maps provides a red-black tree with Floor/Ceiling
-- operations (Ada 2012+), making it the natural comparison for FAST.
--
-- Compile:
--   gnatmake -O3 -gnat2012 -aI../../bindings/ada bench_ada.adb \
--       -o bench_ada -largs -L../../build -lfast -Wl,-rpath,../../build

with Ada.Command_Line;
with Ada.Text_IO;           use Ada.Text_IO;
with Ada.Calendar;           use Ada.Calendar;
with Interfaces.C;           use Interfaces.C;
with Ada.Unchecked_Deallocation;
with System;
with Fast_Binding;           use Fast_Binding;
with Ada.Containers.Ordered_Maps;

procedure Bench_Ada is

   type Int32_Array is array (Positive range <>) of Interfaces.C.int;
   pragma Convention (C, Int32_Array);

   type Int32_Array_Access is access Int32_Array;
   type Query_Array is array (Positive range <>) of Interfaces.C.int;
   type Query_Array_Access is access Query_Array;

   procedure Free_Keys is new Ada.Unchecked_Deallocation
      (Int32_Array, Int32_Array_Access);
   procedure Free_Queries is new Ada.Unchecked_Deallocation
      (Query_Array, Query_Array_Access);

   -- Instantiate ordered map: int -> Long_Integer (red-black tree)
   package Int_Ordered_Maps is new Ada.Containers.Ordered_Maps
      (Key_Type     => Interfaces.C.int,
       Element_Type => Long_Integer);
   use Int_Ordered_Maps;

   Tree_Size   : Natural := 1_000_000;
   Num_Queries : Natural := 5_000_000;
   Warmup      : Natural;

   procedure Emit_JSON (Method : String; Sec : Duration) is
      MQS : constant Long_Float := Long_Float (Num_Queries) / Long_Float (Sec) / 1.0e6;
      NSQ : constant Long_Float := Long_Float (Sec) * 1.0e9 / Long_Float (Num_Queries);
   begin
      Put_Line ("{""language"":""ada"",""compiler"":""gnat""," &
                """method"":""" & Method & """," &
                """tree_size"":" & Natural'Image (Tree_Size) & "," &
                """num_queries"":" & Natural'Image (Num_Queries) & "," &
                """total_sec"":" & Long_Float'Image (Long_Float (Sec)) & "," &
                """mqs"":" & Long_Float'Image (MQS) & "," &
                """ns_per_query"":" & Long_Float'Image (NSQ) & "}");
      Flush;
   end Emit_JSON;

   Keys    : Int32_Array_Access;
   Queries : Query_Array_Access;
   Max_Key : Interfaces.C.int;
   Seed    : Long_Integer := 42;
   Sink    : Long_Integer := 0;
   T0, T1  : Time;
   Tree    : Fast_Tree;
   Map     : Int_Ordered_Maps.Map;
   Cur     : Int_Ordered_Maps.Cursor;

begin
   -- Parse arguments
   if Ada.Command_Line.Argument_Count >= 1 then
      Tree_Size := Natural'Value (Ada.Command_Line.Argument (1));
   end if;
   if Ada.Command_Line.Argument_Count >= 2 then
      Num_Queries := Natural'Value (Ada.Command_Line.Argument (2));
   end if;
   Warmup := Natural'Min (Num_Queries, 100_000);

   -- Heap-allocate keys and queries to avoid stack overflow
   Keys := new Int32_Array (1 .. Tree_Size);
   Queries := new Query_Array (1 .. Num_Queries);

   -- Generate sorted keys
   for I in Keys.all'Range loop
      Keys.all (I) := Interfaces.C.int ((I - 1) * 3 + 1);
   end loop;
   Max_Key := Keys.all (Tree_Size);

   -- Generate random queries (simple LCG)
   for I in Queries.all'Range loop
      Seed := (Seed * 1103515245 + 12345) mod 2_147_483_648;
      Queries.all (I) := Interfaces.C.int (Seed mod Long_Integer (Max_Key + 1));
   end loop;

   -- --- FAST FFI ---
   Tree := Fast_Create (Keys.all (1)'Address, Interfaces.C.size_t (Tree_Size));

   for I in 1 .. Warmup loop
      Sink := Sink + Fast_Search (Tree, Queries.all (I));
   end loop;

   T0 := Clock;
   for I in 1 .. Num_Queries loop
      Sink := Sink + Fast_Search (Tree, Queries.all (I));
   end loop;
   T1 := Clock;
   Emit_JSON ("fast_ffi", T1 - T0);

   Fast_Destroy (Tree);

   -- --- Ada.Containers.Ordered_Maps (red-black tree) ---
   -- Build the ordered map
   for I in Keys.all'Range loop
      Map.Insert (Keys.all (I), Long_Integer (I - Keys.all'First));
   end loop;

   -- Warmup
   for I in 1 .. Warmup loop
      Cur := Floor (Map, Queries.all (I));
      if Has_Element (Cur) then
         Sink := Sink + Element (Cur);
      else
         Sink := Sink - 1;
      end if;
   end loop;

   T0 := Clock;
   for I in 1 .. Num_Queries loop
      Cur := Floor (Map, Queries.all (I));
      if Has_Element (Cur) then
         Sink := Sink + Element (Cur);
      else
         Sink := Sink - 1;
      end if;
   end loop;
   T1 := Clock;
   Emit_JSON ("Ordered_Maps", T1 - T0);

   -- Cleanup
   Free_Keys (Keys);
   Free_Queries (Queries);

   -- Prevent optimization
   if Sink = Long_Integer'First then
      Put_Line (Standard_Error, Long_Integer'Image (Sink));
   end if;
end Bench_Ada;
