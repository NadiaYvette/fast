-- Ada bindings for the FAST search tree library.
--
-- Usage:
--   with Fast_Binding; use Fast_Binding;
--   Tree : Fast_Tree := Fast_Create(Keys'Address, Keys'Length);
--   Idx  : Long_Integer := Fast_Search(Tree, 5);
--   Fast_Destroy(Tree);

with Interfaces.C;          use Interfaces.C;
with Interfaces.C.Strings;
with System;

package Fast_Binding is

   type Fast_Tree is new System.Address;
   Null_Tree : constant Fast_Tree := Fast_Tree (System.Null_Address);

   function Fast_Create
     (Keys : System.Address;
      N    : Interfaces.C.size_t) return Fast_Tree
     with Import => True, Convention => C, External_Name => "fast_create";

   procedure Fast_Destroy (Tree : Fast_Tree)
     with Import => True, Convention => C, External_Name => "fast_destroy";

   function Fast_Search
     (Tree : Fast_Tree;
      Key  : Interfaces.C.int) return Long_Integer
     with Import => True, Convention => C, External_Name => "fast_search";

   function Fast_Search_Lower_Bound
     (Tree : Fast_Tree;
      Key  : Interfaces.C.int) return Long_Integer
     with Import => True, Convention => C,
          External_Name => "fast_search_lower_bound";

   function Fast_Size (Tree : Fast_Tree) return Interfaces.C.size_t
     with Import => True, Convention => C, External_Name => "fast_size";

   function Fast_Key_At
     (Tree  : Fast_Tree;
      Index : Interfaces.C.size_t) return Interfaces.C.int
     with Import => True, Convention => C, External_Name => "fast_key_at";

end Fast_Binding;
