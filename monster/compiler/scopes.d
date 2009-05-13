/*
  Monster - an advanced game scripting language
  Copyright (C) 2007-2009  Nicolay Korslund
  Email: <korslund@gmail.com>
  WWW: http://monster.snaptoad.com/

  This file (scopes.d) is part of the Monster script language package.

  Monster is distributed as free software: you can redistribute it
  and/or modify it under the terms of the GNU General Public License
  version 3, as published by the Free Software Foundation.

  This program is distributed in the hope that it will be useful, but
  WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
  General Public License for more details.

  You should have received a copy of the GNU General Public License
  version 3 along with this program. If not, see
  http://www.gnu.org/licenses/ .

 */

module monster.compiler.scopes;

import std.stdio;
import std.string;

import monster.util.aa;

import monster.compiler.statement;
import monster.compiler.expression;
import monster.compiler.tokenizer;
import monster.compiler.types;
import monster.compiler.assembler;
import monster.compiler.properties;
import monster.compiler.functions;
import monster.compiler.states;
import monster.compiler.structs;
import monster.compiler.enums;
import monster.compiler.variables;

import monster.vm.mclass;
import monster.vm.error;
import monster.vm.vm;

//debug=lookupTrace;

// The global scope
RootScope global;

void initScope()
{
  global = new RootScope;
}

// List all identifier types
enum LType
  {
    None,
    Class,
    Type,
    Variable,
    Function,
    State,
    StateLabel,
    LoopLabel,
    Property,
    Import,
    Package,
  }

const char[][] LTypeName =
  [
   LType.None: "",
   LType.Class: "class",
   LType.Type: "type",
   LType.Variable: "variable",
   LType.Function: "function",
   LType.State: "state",
   LType.StateLabel: "state label",
   LType.LoopLabel: "loop label",
   LType.Property: "property",
   LType.Package: "package",
   ];

struct ScopeLookup
{
  Token name;
  LType ltype;

  Scope sc;
  Type type;
  union
  {
    MonsterClass mc;
    Variable* var;
    Function* func;
    State* state;
    StateLabel *slabel;
    ImportHolder imphold;

    void *ptr;
    Object ob;
  }

  bool isClass() { return ltype == LType.Class; }
  bool isType() { return ltype == LType.Type; }
  bool isVar() { return ltype == LType.Variable; }
  bool isFunc() { return ltype == LType.Function; }
  bool isState() { return ltype == LType.State; }
  bool isNone() { return ltype == LType.None; }
  bool isImport() { return ltype == LType.Import; }
  bool isPackage() { return ltype == LType.Package; }
  bool isProperty()
  {
    bool ret = (ltype == LType.Property);
    assert( ret == (cast(PropertyScope)sc !is null) );
    return ret;
  }

  // For properties only
  Type getPropType(Type owner)
  {
    assert(type is null);
    assert(owner !is null);
    assert(name.str != "");
    
    type = owner;
    return ps().getType(name.str, owner);
  }
  private PropertyScope ps()
  {
    assert(isProperty);
    assert(type !is null);
    return cast(PropertyScope)sc;
  }
  bool isPropLValue() { return ps().isLValue(name.str, type); }
  bool isPropStatic() { return ps().isStatic(name.str, type); }
  void getPropValue() { ps().getValue(name.str, type); }
  void setPropValue() { ps().setValue(name.str, type); }

  static ScopeLookup opCall(Token nm, LType lt, Type tp, Scope sc, Object ob)
  {
    auto sl = ScopeLookup(nm, lt, tp, sc);
    sl.ob = ob;
    return sl;
  }

  static ScopeLookup opCall(Token nm, LType lt, Type tp, Scope sc, void*p = null)
  {
    assert(nm.str != "");

    ScopeLookup sl;
    sl.name = nm;
    sl.ltype = lt;
    sl.type = tp;
    sl.sc = sc;
    sl.ptr = p;
    return sl;
  }
}


// TODO: Write here which of these should be kept around at runtime,
// and which of them can be discarded after compilation.

abstract class Scope
{
 protected:
  // The parent scope. For function scopes, this is the scope of the
  // class it belongs to. For code blocks, loops etc, it is the scope
  // of the code block outside this one. For classes, this points to
  // the scope of the parent class, if any, or to the package or
  // global scope.
  Scope parent;

  // Made protected since it is so easy to confuse with isStateCode(),
  // and we never actually need it anywhere outside this file.
  bool isState() { return false; }

 private:
  // Name of this scope. All scopes must have a name, but for some
  // types it is set automatically (like a code block scope.) It is
  // mostly used for debugging.
  char[] scopeName;

  ImportHolder importList[];

 public:

  this(Scope last, char[] name)
  {
    scopeName = name;
    parent = last;

    assert(last !is this, "scope cannot be it's own parent");
    assert(name != "");

    // Copy the import list from our parent
    if(!isRoot)
      importList = parent.importList;
  }

  // Verify that an identifier is not declared in this scope. If the
  // identifier is found, give a duplicate identifier compiler
  // error. Recurses through parent scopes.
  final void clearId(Token name)
    {
      debug(lookupTrace)
        writefln("ClearId %s in %s (line %s)", name, this, __LINE__);

      // Lookup checks all parent scopes so we only have to call it
      // once.
      auto sl = lookup(name, false);

      if(!sl.isNone)
        {
          if(sl.isProperty)
            fail(name.str ~ " is a property and cannot be redeclared",
                 name.loc);

          char[] oldLoc = name.loc.toString;

          // There might be a case insensitive match. In that case we
          // should print the original name as well.
          if(sl.name.str != name.str)
            oldLoc ~= " as " ~ sl.name.str;

          fail(format("%s is already declared as a %s (at %s)",
                      name.str, LTypeName[sl.ltype], oldLoc),
               name.loc);
        }
      assert(sl.name.str == name.str);
    }

  // Is this the root scope?
  final bool isRoot()
    {
      if(parent !is null) return false;
      assert(allowRoot(), toString() ~ " cannot be a root scope");
      return true;
    }

  // Is THIS scope of this particular kind?
  bool isFunc() { return false; }
  bool isCode() { return false; }
  bool isLoop() { return false; }
  bool isClass() { return false; }
  bool isArray() { return false; }
  bool isStruct() { return false; }
  bool isPackage() { return false; }
  bool isProperty() { return false; }

  // Is this scope allowed to be a root scope (without parent?)
  bool allowRoot() { return false; }

  // Get the function definition belonging to this scope.
  Function *getFunction()
  {
    assert(!isRoot(), "getFunction called on a root scope");
    return parent.getFunction();
  }

  // Get the class
  MonsterClass getClass()
  {
    assert(!isRoot(), "getClass called on a root scope");
    return parent.getClass();
  }

  State* getState()
  {
    assert(!isRoot(), "getState called on a root scope");
    return parent.getState();
  }

  Expression getArray()
  {
    assert(!isRoot(), "getArray called on wrong scope type");
    return parent.getArray();
  }

  PackageScope getPackage()
  {
    assert(!isRoot(), "getPackage called on the wrong scope type");
    return parent.getPackage();
  }

  int getLoopStack()
  {
    assert(!isRoot(), "getLoopStack called on wrong scope type");
    return parent.getLoopStack();
  }

  // Get the break or continue label for the given named loop, or the
  // innermost loop if name is empty or omitted. Returns null if the
  // label was not found. Can only be called within loops.
  LabelStatement getBreak(char[] name = "") { return null; }
  LabelStatement getContinue(char[] name = "") { return null; }

  // Lookup a string
  final ScopeLookup lookupName(char[] name)
    { return lookup(Token(name, Floc.init)); }

  // Look up a token in this scope. If autoLoad is true, load classes
  // automatically if a file exists.
  ScopeLookup lookup(Token name, bool autoLoad=false)
    {
      debug(lookupTrace)
        writefln("Lookup %s in %s (line %s)", name, this, __LINE__);
      if(isRoot()) return ScopeLookup(name, LType.None, null, null);
      else return parent.lookup(name, autoLoad);
    }

  // Look up a token in this scope. If the token is not found, try the
  // lookup again and check the file system for classes.
  ScopeLookup lookupClass(Token name)
    {
      auto sl = lookup(name);
      if(sl.isNone)
        sl = lookup(name, true);
      return sl;
    }

  // Look up an identifier, and check imported scopes as well. If the
  // token is not found, do the lookup again but this time check the
  // file system for classes as well.
  ScopeLookup lookupImport(Token name, bool second=false)
    {
      debug(lookupTrace)
        writefln("LookupImport %s in %s (line %s)", name, this, __LINE__);
      auto l = lookup(name, second);
      if(!l.isNone) return l;

      // Nuttin' was found, try the imports
      bool found = false;
      auto old = l;
      foreach(imp; importList)
        {
          l = imp.lookup(name, second);

          // Only accept types, classes, variables and functions
          if(l.isType || l.isClass || l.isVar || l.isFunc)
            {
              // Duplicate matches aren't allowed
              if(found && l.sc !is old.sc)
                fail(format(
  "%s matches both %s.%s (at %s) and %s.%s (at %s)", name.str,
  old.imphold.getName(), old.name.str, old.name.loc,
  imp.getName(), l.name.str, l.name.loc),
                     name.loc);

              // First match
              found = true;
              old = l;
              old.imphold = imp;
            }
        }

      if(!found)
        {
          // If we haven't tried searching the file system for
          // classes, try that.
          if(!second)
            return lookupImport(name, true);

          return ScopeLookup(name, LType.None, null, null);
        }

      // Tell the caller that this is an import. We override the
      // lookup struct, but it doesn't matter since the lookup will
      // have to be performed again anyway.
      old.ltype = LType.Import;
      assert(old.imphold !is null);
      return old;
    }

  // Add an import to this scope
  void registerImport(ImportHolder s)
    {
      //writefln("Registering import %s in scope %s", s, this);
      importList ~= s;
    }

  // More user-friendly version for API-defined
  // imports. Eg. global.registerImport(myclass) -> makes myclass
  // available in ALL classes.
  void registerImport(MonsterClass mc)
    { registerImport(new ClassImpHolder(mc)); }

  // Even more user-friendly version. Takes a list of class names.
  void registerImport(char[][] cls ...)
    {
      foreach(c; cls)
        registerImport(vm.load(c));
    }

  // Used for summing up stack level. Redeclared in StackScope.
  int getTotLocals() { return 0; }
  int getLocals() { assert(0); }

  // This must be overridden in all scopes that allow variable
  // declarations.
  int addNewVar(int varSize) { assert(0); }

 final:

  bool isStateCode()
    { return isInState() && !isInFunc(); }

  // Is this scope OR one of the parent scopes of the given kind?
  bool isInFunc()
    {
      if(isFunc()) return true;
      if(isRoot()) return false;
      return parent.isInFunc();
    }
  bool isInState()
    {
      if(isState()) return true;
      if(isRoot()) return false;
      return parent.isInState();
    }
  bool isInLoop()
    {
      if(isLoop()) return true;
      if(isRoot()) return false;
      return parent.isInLoop();
    }
  bool isInClass()
    {
      if(isClass()) return true;
      if(isRoot()) return false;
      return parent.isInClass();
    }
  bool isInPackage()
    {
      if(isPackage()) return true;
      if(isRoot()) return false;
      return parent.isInPackage();
    }

  char[] toString()
  {
    if(parent is null) return scopeName;
    else return parent.toString() ~ "." ~ scopeName;
  }
}

final class StateScope : Scope
{
 private:
  State* st;

 public:

  this(Scope last, State* s)
    {
      st = s;
      super(last, st.name.str);
    }

  // Insert a label, check for name collisions.
  void insertLabel(StateLabel *lb)
    {
      // Check for name collisions
      clearId(lb.name);

      st.labels[lb.name.str] = lb;
    }

  override:
  ScopeLookup lookup(Token name, bool autoLoad=false)
    {
      debug(lookupTrace)
        writefln("Lookup %s in %s (line %s)", name, this, __LINE__);

      assert(name.str != "");

      // Check against state labels
      StateLabel *lb;
      if(st.labels.inList(name.str, lb))
        return ScopeLookup(lb.name, LType.StateLabel, null, this, lb);

      return super.lookup(name, autoLoad);
    }

  State* getState() { return st; }

  bool isState() { return true; }
}

final class RootScope : PackageScope
{
 private:
  // Lookup by integer index. The indices are global, that is why they
  // are stored in the root scope rather than in the individual
  // packages.
  HashTable!(CIndex, MonsterClass) indexList;

  // Forward references. Refers to unloaded and non-existing
  // classes. TODO: This mechanism probably won't work very well with
  // multiple packages. It should be possible to have forward
  // references to multiple classes with the same name, as long as
  // they are in the correct packages. Think it over some more.
  HashTable!(char[], CIndex) forwards;

  // Unique global index to give the next class.
  CIndex next = 1;

 public:
  this() { super(null, "global", ""); }
  bool allowRoot() { return true; }

  // Get a class by index
  MonsterClass getClass(CIndex ind)
    {
      MonsterClass mc;
      if(!indexList.inList(ind, mc))
        fail("Invalid class index encountered");
      mc.requireScope();
      return mc;
    }

  // Gets the index of a class, or inserts a forward reference to it
  // if cannot be found. Subsequent calls for the same name will
  // insert the same index, and when/if the class is actually loaded
  // it will get the same index.
  CIndex getForwardIndex(char[] name)
    {
      // Called when an existing forward does not exist
      void inserter(ref CIndex v)
        { v = next++; }

      // Return the index in forwards, or create a new one if none
      // exists.
      return forwards.get(name, &inserter);
    }

  // Returns true if a given class has been inserted into the scope.
  bool isLoaded(CIndex ci)
    {
      return indexList.inList(ci);
    }

  override ScopeLookup lookup(Token name, bool autoLoad=false)
    {
      debug(lookupTrace)
        writefln("Lookup %s in %s (line %s)", name, this, __LINE__);

      // Basic types are looked up here
      if(BasicType.isBasic(name.str))
        return ScopeLookup(name, LType.Type, BasicType.get(name.str), this);

      // Return ourselves as the package named 'global'
      if(name.str == "global")
        return ScopeLookup(name, LType.Package, type, this);

      // No parents to check
      assert(isRoot());
      return super.lookup(name, autoLoad);
    }
}

// A package scope is a scope that can contain classes.
class PackageScope : Scope
{
 private:
  // List of classes in this package. This is case insensitive, so we
  // can look up file names too.
  HashTable!(char[], MonsterClass, GCAlloc, CITextHash) classes;

  // List of sub-packages
  HashTable!(char[], PackageScope, GCAlloc, CITextHash) children;

  char[] path;

 public:
  // The type is used for expression lookups, eg. packname.Class(obj);
  PackageType type;

  this(Scope last, char[] name, char[] dir)
    {
      super(last, name);

      auto ps = cast(PackageScope) last;
      assert(last is null || ps !is null,
             "Packages can only have other packages as parent scopes");

      path = dir;
      assert(!path.begins("/"));

      assert(vm.vfs !is null);
      if(dir != "" && !vm.vfs.hasDir(dir))
        fail("Cannot create package "~toString~": directory "
             ~dir~" not found");

      type = new PackageType(this);
    }

  bool isPackage() { return true; }

  PackageScope getPackage()
    {
      return this;
    }

  char[] getPath(char[] file)
    {
      if(path == "") return file;

      file = path ~ "/" ~ file;
      assert(file[0] != '/');
      return file;
    }

  // Insert a new sub-package, or find an existing one. All package
  // names are case insensitive. Returns the package scope. Fails if
  // there are naming conflicts with other identifiers.
  PackageScope insertPackage(char[] name)
    {
      auto sl = lookupName(name);

      if(!sl.isPackage)
        fail(format("Package name %s is already declared (at %s) as a %s",
                    sl.name.str, sl.name.loc, LTypeName[sl.ltype]));
      if(sl.isNone)
        fail("Cannot find package " ~ name);

      auto ps = cast(PackageScope)sl.sc;
      assert(ps !is null);
      return ps;
    }

  // Used internally from lookup()
  private PackageScope makeSubPackage(char[] name)
    {
      debug(lookupTrace)
        writefln("Lookup %s in %s (line %s)", name, this, __LINE__);

      if(!isValidIdent(name))
        fail("Cannot create package " ~ name ~ ": not a valid identifier");

      assert(!children.inList(name));

      PackageScope ps;
      ps = new PackageScope(this, name, getPath(name));
      children[name] = ps;

      return ps;
    }

  // Insert a new class into the scope. The class is given a unique
  // global index. If the class was previously forward referenced, the
  // forward is replaced and the previously assigned forward index is
  // used. A class can only be inserted once.
  void insertClass(MonsterClass cls)
  {
    assert(cls !is null);
    assert(cls.name.str != "");

    // Are we already in the list?
    MonsterClass c2;
    if(ciInList(cls.name.str, c2))
      {
        // That's not allowed. Determine what error message to give.

        if(c2.name.str == cls.name.str)
          // Exact name collision
          fail("Cannot load class " ~ cls.name.str ~
               " because it is already loaded.");

        // Case insensitive match
        fail("Cannot load class " ~ cls.name.str ~ " because "
             ~ c2.name.str ~
             " already exists (class names cannot differ only by case.)");
      }

    // Check that no other identifier with this name exists
    clearId(cls.name);

    // We're clear. Find an index to use. If the class was forward
    // referenced, then an index has already been assigned.
    CIndex ci;

    if(global.forwards.inList(cls.name.str, ci))
      {
        if(this !is global)
          fail("Class " ~ cls.name.str ~ " was forward referenced and can only be added to the 'global' package, not to " ~ toString);

        // ci is set, remove the entry from the forwards hashmap
        assert(ci != 0);
        global.forwards.remove(cls.name.str);
      }
    else
      // Get a new index
      ci = global.next++;

    assert(!global.indexList.inList(ci));

    // Assign the index and insert class into both lists
    cls.gIndex = ci;
    classes[cls.name.str] = cls;
    global.indexList[ci] = cls;

    assert(global.indexList.inList(ci));
  }

  // Case insensitive lookups. Used for comparing with file names,
  // before the actual class is loaded.
  bool ciInList(char[] name)
    { return classes.inList(name); }
  bool ciInList(char[] name, out MonsterClass cb)
    { return classes.inList(name, cb); }

  // Case sensitive versions. If a class is found that does not match
  // in case, it is an error.
  bool csInList(char[] name, out MonsterClass cb)
    {
      bool result = ciInList(name, cb) && cb.name.str == name;

      // The caller depends on the output to be null if the search
      // fails.
      if(!result) cb = null;

      return result;
    }

  override ScopeLookup lookup(Token name, bool autoLoad=false)
    {
      debug(lookupTrace)
        writefln("Lookup %s in %s (line %s)", name, this, __LINE__);

      // Look up packages
      PackageScope psc;
      if(!children.inList(name.str, psc))
        // Check the file system if there is a matching directory
        if(vm.vfs.hasDir(getPath(name.str)))
          psc = makeSubPackage(name.str);

      if(psc !is null)
        return ScopeLookup(name, LType.Package, psc.type, psc);

      // Look up classes
      MonsterClass mc;
      if(!csInList(name.str, mc) && autoLoad)
        {
          // Load the class from file, if it exists
          mc = vm.loadNoFail(name.str,
                             tolower(getPath(name.str))~".mn");
        }

      if(mc !is null)
        return ScopeLookup(mc.name, LType.Class, null, this, mc);

      // Unlike other scopes, a package scope doesn't check through
      // all its parent packages. That would mean that a name search
      // for a package or a class could 'leak' out of a directory and
      // find the wrong match. Instead we jump directly to the root
      // scope.

      // If we're the root scope, super.lookup will return an empty
      // result.
      if(isRoot()) return super.lookup(name, autoLoad);

      // Otherwise, jump directly to root, do not collect 200 dollars.
      assert(global !is this);
      return global.lookup(name, autoLoad);
    }
}

// A scope that can contain variables.
abstract class VarScope : Scope
{
 private:
  HashTable!(char[], Variable*) variables;

 public:

  this(Scope last, char[] name)
    { super(last, name); }

  // Insert a variable, checks if it already exists.
  void insertVar(Variable* dec)
  {
    assert(!isStateCode, "called insertVar in state code");

    // Check for name collisions.
    clearId(dec.name);

    variables[dec.name.str] = dec;
  }

 override:

  ScopeLookup lookup(Token name, bool autoLoad=false)
    {
      debug(lookupTrace)
        writefln("Lookup %s in %s (line %s)", name, this, __LINE__);

      assert(name.str != "");

      Variable *vd;
      if(variables.inList(name.str, vd))
        return ScopeLookup(vd.name, LType.Variable, vd.type, this, vd);

      return super.lookup(name, autoLoad);
    }  
}

// A scope that can contain functions and variables
class FVScope : VarScope
{
 protected:
  HashTable!(char[], Function*) functions;

 public:
  this(Scope last, char[] name)
    { super(last, name); }

  // Insert a function.
  void insertFunc(Function* fd)
  {
    if(isClass)
      {
        // Are we overriding a function?
        auto look = lookup(fd.name);
        if(look.isFunc)
          // We're overriding. Let fd know, and let it handle the
          // details when it resolves.
          fd.overrides = look.func;
        else
          // No matching function. Check that the name is available.
          clearId(fd.name);
      }
    else
      // Non-class functions can never override anything
      clearId(fd.name);

    fd.index = functions.length;

    // Store the function definition
    functions[fd.name.str] = fd;
  }

  override:
  ScopeLookup lookup(Token name, bool autoLoad=false)
    {
      debug(lookupTrace)
        writefln("Lookup %s in %s (line %s)", name, this, __LINE__);

      assert(name.str != "");

      Function* fd;

      if(functions.inList(name.str, fd))
        return ScopeLookup(fd.name, LType.Function, fd.type, this, fd);

      // Let VarScope handle variables
      return super.lookup(name, autoLoad);
    }
}

// Can contain types, functions and variables. 'Types' means structs,
// enums and other user-generated sub-types (may also include classes
// later.)

// The TFV, FV and Var scopes might (probably will) be merged at some
// point. I'm just keeping them separate for clearity while the scope
// structure is being developed.
class TFVScope : FVScope
{
 private:
  HashTable!(char[], StructType) structs;
  HashTable!(char[], EnumType) enums;

 public:
  this(Scope last, char[] name)
    { super(last, name); }

  void insertStruct(StructDeclaration sd)
  {
    clearId(sd.name);
    structs[sd.name.str] = sd.type;
  }

  void insertEnum(EnumType sd)
  {
    clearId(sd.nameTok);
    enums[sd.name] = sd;
  }

  override:
  ScopeLookup lookup(Token name, bool autoLoad=false)
    {
      debug(lookupTrace)
        writefln("Lookup %s in %s (line %s)", name, this, __LINE__);

      assert(name.str != "");

      StructType sd;
      EnumType ed;
      Type tp;

      if(structs.inList(name.str, sd)) tp = sd;
      else if(enums.inList(name.str, ed)) tp = ed;

      if(tp !is null)
        return ScopeLookup(Token(tp.name, tp.loc), LType.Type, tp, this);

      // Pass it on to the parent
      return super.lookup(name, autoLoad);
    }
}

// Lookup scope for enums. For simplicity we use the property system
// to handle enum members.
final class EnumScope : SimplePropertyScope
{
  this(EnumType _et)
    {
      super("EnumScope", GenericProperties.singleton);
      et = _et;

      insert("value", "long", &enumVal);
      inserts("length", "int", &enumLen);
      inserts("first", et, &enumFirst);
      inserts("last", et, &enumLast);
      inserts("min", "long", &enumMin);
      inserts("max", "long", &enumMax);
    }

  void enumMin()
    { tasm.push8(et.minVal); }

  void enumMax()
    { tasm.push8(et.maxVal); }

  void enumFirst()
    { tasm.push(et.entries[0].index); }

  void enumLast()
    { tasm.push(et.entries[$-1].index); }

  void enumLen()
    { tasm.push(et.entries.length); }

  void enumVal()
    { tasm.getEnumValue(et.tIndex); }

  EnumType et;

 override:

  // Intercept all the enum entry names when used as properties
  Type getType(char[] name, Type oType)
    {
      // Is it one of the enum values?
      auto ee = et.lookup(name);
      if(ee !is null)
        {
          assert(et is oType ||
                 et.getMeta() is oType);
          return et;
        }

      // Maybe one of the fields?
      int fe = et.findField(name);
      if(fe != -1)
        return et.fields[fe].type;

      return super.getType(name, oType);
    }

  void getValue(char[] name, Type oType)
    {
      auto ee = et.lookup(name);
      if(ee !is null)
        {
          assert(et is oType ||
                 et.getMeta() is oType);
          tasm.push(ee.index);
          return;
        }

      int fe = et.findField(name);
      if(fe != -1)
        {
          // We're getting a field from a variable. Eg.
          // en.errorString. The enum index is on the stack, and
          // getEnumValue supplies the enum type and the field
          // index. The VM can find the correct field value from that.
          tasm.getEnumValue(et.tIndex, fe);
          return;
        }

      super.getValue(name, oType);
    }

  bool hasProperty(char[] name)
    {
      auto ee = et.lookup(name);
      if(ee !is null) return true;
      if(et.findField(name) != -1)
        return true;
      return super.hasProperty(name);
    }

  bool isStatic(char[] name, Type oType)
    {
      auto ee = et.lookup(name);
      if(ee !is null)
        {
          assert(et is oType ||
                 et.getMeta() is oType);
          return true;
        }

      // The fields are always non-static, they depend on the actual
      // enum value supplied.
      if(et.findField(name) != -1)
        return false;

      return super.isStatic(name, oType);
    }

  bool isLValue(char[] name, Type oType)
    {
      // We can't override anything in an enum
      auto ee = et.lookup(name);
      if(ee !is null)
        {
          assert(et is oType ||
                 et.getMeta() is oType);
          return false;
        }
      if(et.findField(name) != -1)
        return false;
      return super.isLValue(name, oType);
    }
}

// Scope for the interior of structs
final class StructScope : VarScope
{
  int offset;

  StructType str;

  this(Scope last, StructType t)
    {
      str = t;
      assert(str !is null);
      super(last, t.name);
    }

  bool isStruct() { return true; }

  int addNewVar(int varSize)
    { return (offset+=varSize) - varSize; }

  // Define it only here since we don't need it anywhere else.
  Scope getParent() { return parent; }
}

// A class scope. In addition to variables, and functions, classes can
// contain states and they keep track of the data segment size.
final class ClassScope : TFVScope
{
 private:
  // The class information for this class.
  MonsterClass cls;

  HashTable!(char[], State*) states;
  int dataSize;    // Data segment size for this class

 public:

  this(Scope last, MonsterClass cl)
    {
      cls = cl;
      super(last, cls.name.str);
    }

  bool isClass() { return true; }
  MonsterClass getClass() { return cls; }

  // Add a variable to the data segment, returns the offset.
  int addNewVar(int varSize)
  {
    int tmp = dataSize;

    dataSize += varSize;

    return tmp;
  }

  override ScopeLookup lookup(Token name, bool autoLoad=false)
    {
      debug(lookupTrace)
        writefln("Lookup %s in %s (line %s)", name, this, __LINE__);

      assert(name.str != "");

      State* sd;

      if(states.inList(name.str, sd))
        return ScopeLookup(sd.name, LType.State, null, this, sd);

      // Check the property list
      auto sl = ClassProperties.singleton.lookup(name);
      if(sl.isProperty)
        return sl;

      // Let the parent handle everything else
      return super.lookup(name, autoLoad);
    }  

  // Get total data segment size
  int getDataSize() { return dataSize; }

  // Insert a state
  void insertState(State* st)
  {
    clearId(st.name);

    st.index = states.length;
    states[st.name.str] = st;
  }
}

// A scope that keeps track of the stack
abstract class StackScope : VarScope
{
 private:
  int locals; // The number of local variables declared in this
	      // scope. These must be pop'ed when the scope exits.
  int sumLocals;// Current position of the stack relative to the stack
		// pointer. This is set to zero at the start of the
		// function, and increased for each local variable
		// that is added. The difference between sumLocals and
		// locals is that sumLocals counts ALL local variables
		// declared in the current function (above the current
		// point), while locals only counts THIS scope.

  int expStack; // Expression stack. Only eeps track of intra-
                // expression stack values, and must end up at zero
                // after each statement.

 public:
  this(Scope last, char[] name)
  {
    super(last, name);

    // Local variable position is inherited
    assert(!isRoot());
    sumLocals = parent.getTotLocals;
  }

  // Allocate a local variable on the stack, and return the offset.
  // The parameter gives the size of the requested variable in ints (4
  // bytes.)
  int addNewVar(int varSize)
  {
    assert(expStack == 0);

    locals += varSize;

    int tmp = sumLocals;
    sumLocals += varSize;

    return tmp;
  }

  // Reset the stack counters. Used from the console.
  void reset()
    {
      locals = 0;
      sumLocals = 0;
    }

  /*
  void push(int i) { expStack += i; }
  void push(Type t) { push(t.getSize); }
  void pop(int i) { expStack -= i; }
  void pop(Type t) { pop(t.getSize); }
  */

  // Get the number of local variables in the current scope. In
  // reality it gives the number of ints. A variable 8 bytes long will
  // count as two variables.
  int getLocals() { return locals; }

  // Get the total number of local variables for this function. Used
  // in return statements and by other jumps that might span several
  // blocks (break and continue.)
  int getTotLocals() { return sumLocals; }

  // Get intra-expression stack (not used yet)
  int getExpStack() { return expStack; }

  // Get total stack position, including expression stack values. This
  // is used by the array lenght symbol $ to find the array index.
  int getPos() { return getTotLocals() + getExpStack(); }
}

// Scope used for the inside of functions
class FuncScope : StackScope
{
  // Function definition, for function scopes
 private:
  Function *fnc;

 public:
  this(Scope last, Function *fd)
    {
      super(last, fd.name.str);
      fnc = fd;
    }

 override:

  bool isFunc() { return true; }
  Function *getFunction() { return fnc; }
}

class CodeScope : StackScope
{
  this(Scope last, CodeBlock cb)
    {
      char[] name = "codeblock";

      assert(cb !is null);
      if(cb.isState)
        name = "stateblock";

      super(last, name);
    }

  this(Scope last, char[] name) { super(last, name) ;}

  bool isCode() { return true; }

  LabelStatement getBreak(char[] name = "") { return parent.getBreak(name); }
  LabelStatement getContinue(char[] name = "") { return parent.getContinue(name); }
}

// Experimental! Used to recompute the array expression for $. NOT a
// permanent solution.
class ArrayScope : StackScope
{
  private Expression expArray;

  this(Scope last, Expression arr)
    {
      super(last, "arrayscope");
      expArray = arr;
    }

  bool isArray() { return true; }
  Expression getArray() { return expArray; }
}

// Base class for scopes that have properties. The instances of this
// scope are defined in properties.d
abstract class PropertyScope : Scope
{
  this(char[] n, PropertyScope last = null) { super(last, n); }

  // Override these in base classes.

  Type getType(char[] name, Type oType);
  void getValue(char[] name, Type oType);
  bool hasProperty(char[] name);
  bool isStatic(char[] name, Type oType);

  // Most properties are read-only, but override these for exceptions.
  bool isLValue(char[] name, Type oType) { return false; }
  void setValue(char[] name, Type oType) { assert(0); }

 override:
 final:
  bool isProperty() { return true; }
  bool allowRoot() { return true; }

  ScopeLookup lookup(Token name, bool autoLoad=false)
    {
      debug(lookupTrace)
        writefln("Lookup %s in %s (line %s)", name, this, __LINE__);

      // Does this scope contain the property?
      if(hasProperty(name.str))
        return ScopeLookup(name, LType.Property, null, this);

      // Check the parent scope
      return super.lookup(name, autoLoad);
    }
}

// Scope inside of loops. Handles break and continue, loop labels, and
// some stack stuff.
class LoopScope : CodeScope
{
 private:
  LabelStatement breakLabel, continueLabel;
  Token loopName; // Loop label name.
  int loopStack = -1; // Stack position of the array index. Only used in
                      // foreach loops.
  bool isForeach; // Redundant variable used for integrity checking only

  // Set the label and set up a nice name
  this(Scope last, char[] name, Token label)
    {
      // Include the label name in the scope name
      if(label.str != "")
        name ~= ":" ~ label.str;

      super(last, name);

      if(label.str != "")
        {
          // This loop has a label, so set it up
          clearId(label);
          loopName = label;
        }
    }

 public:

  this(Scope last, ForStatement fs)
    { this(last, "for-loop", fs.labelName); }
  this(Scope last, ForeachStatement fs)
    {
      this(last, "foreach-loop", fs.labelName);
      isForeach = true;
    }
  this(Scope last, DoWhileStatement fs)
    {
      this(last, "do-while-loop", fs.labelName);
      stackPoint();
    }
  this(Scope last, WhileStatement fs)
    {
      this(last, "while-loop", fs.labelName);
      stackPoint();
    }

  bool isLoop() { return true; }

  // Called when the stack is set up to the level of the loop
  // interior, after loop variables and such are declared. This
  // function should only be called for for-loops and foreach-loops,
  // and will make sure that loop variables are not popped by break
  // and continue statements.
  void stackPoint()
    {
      assert(breakLabel is null && continueLabel is null && loopStack == -1,
             "do not call stackPoint multiple times");

      if(isForeach) loopStack = getTotLocals() - 1;
      breakLabel = new LabelStatement(getTotLocals());
      continueLabel = new LabelStatement(getTotLocals());
    }

  override ScopeLookup lookup(Token name, bool autoLoad=false)
    {
      debug(lookupTrace)
        writefln("Lookup %s in %s (line %s)", name, this, __LINE__);

      assert(name.str != "");

      // Check for loop labels
      if(loopName.str == name.str)
        return ScopeLookup(loopName, LType.LoopLabel, null, this);

      return super.lookup(name, autoLoad);
    }  

  // Get the break or continue label for the given named loop, or the
  // innermost loop if name is empty or omitted. TODO: Might fold
  // these into lookup as well. For non-named labels we could use
  // __closest_loop__ or something like that internally.
  LabelStatement getBreak(char[] name = "")
  {
    if(name == "" || name == loopName.str)
      return breakLabel;

    return parent.getBreak(name);
  }

  LabelStatement getContinue(char[] name = "")
  {
    if(name == "" || name == loopName.str)
      return continueLabel;

    return parent.getContinue(name);
  }

  int getLoopStack()
  {
    assert(loopStack != -1 && isForeach,
           "getLoopStack called for non-foreach scope");
    return loopStack;
  }
}
