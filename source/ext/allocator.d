module ext.allocator;
/// Proof of concept implementation for IAllocator!traits.
/// Based on existing implementation of std.experimental.allocator.
///
/// Provides alternative design for IAllocator interface
/// and allocatorObject() function, parametrized by allocator traits,
/// effectively combining policy-based design and design by introspection.
/// This enables user types (i.e. collections, smart pointers, etc.)
/// to specify their expectations on the allocator, without depending
/// on concrete allocator implementation, and benefit from D's
/// inference capabilities.
/// This removes the need to explicitly declare
/// interfaces such as ISharedAllocator, INoGCAllocator. They are
/// generated at compile time based on the provided traits.
///
/// Contrary to existing std.experimental.allocator implementation,
/// a CAllocatorImpl class is not exposed, it is kept internal to the
/// allocatorObject() function. All interaction with allocator references
/// is assumed to be performed via IAllocator!traits instances.
///
/// @@@TODO@@@:
///     - explore alternative traits approaches, as BitFlags looks
///       too verbose due to explicit construction. Perhaps structs with enums?..
///     - complete implementation of introspection regarding shared
///       memory allocation (iron out the design, propagate to existing
///       allocators in std.experimental.allocator)
///     - @nogc for several IAllocator primitives (properly annotate
///       allocators in std.experimental.allocator)
///     - destruction/deallocation of classes instantiated via
///       allocatorObject() function?
///     - make nothrow a hard requirement on implementations?
///
/// Authors: Stanislav Blinov
import std.typecons : BitFlags, Ternary;
import std.meta : anySatisfy;
import std.experimental.allocator : stateSize, goodAllocSize;
public import std.experimental.allocator : make, dispose;

// a shortcut for testing bitflags
private bool allSet(A,B)(A a, B b)
{
    return (a & A(b)) == A(b);
}

// tests if `ptr` is aligned to `alignment`
private bool isAligned(void* ptr, size_t alignment = (void*).alignof) @trusted
{
    static assert(size_t.sizeof >= (void*).sizeof);
    return ((cast(size_t)ptr % alignment) == 0);
}

unittest
{
    static assert(is(typeof(() @safe { return isAligned(null); } ())));
}

/// Core allocator primitives
/// @nogc and shared are not set explicitly,
/// instead, IAllocator!traits will set those accordingly
mixin template AllocatorInterface()
{
    // required
    Block allocate(size_t, TypeInfo ti = null);

    // optional
    bool deallocate(Block block);
    Block alignedAllocate(size_t, uint);
    Block allocateAll();
    bool expand(ref Block, size_t);
    bool reallocate(ref Block, size_t);
    bool alignedReallocate(ref Block, size_t, uint);
    bool deallocateAll();

//@nogc:
    // these should be @nogc, but e.g. GCAllocator
    // currently doesn't mark them as such
    @property uint alignment() const;
    size_t goodAllocSize(size_t s) const;
    Ternary owns(Block block) const;
    Ternary resolveInternalPointer(void* p, ref Block result) const;
    @property Ternary empty() const;
}

/// Allocator trait bits.
enum AllocTrait
{
    /// no special requirements: unshared non-@nogc interface
    none           = 0x00,
    /// the interface's primitives shall be annotated with @nogc
    nogc           = 0x01,
    /// the interface allocates shared memory
    sharedMemory   = 0x02,
    /// the interface's primitives shall be qualified shared
    sharedInstance = 0x04,

    // @@@TODO@@@ possible enhancements:
    /+
    externalMemory = 0x08,  // i.e. GPU, other process, etc.
    +/
}

alias AllocTraits = BitFlags!(AllocTrait);

interface IAllocatorBase(AllocTraits traits)
{
    // Resolve allocation type.
    // Alternatively, we could always keep it as void[],
    // but require implementations to provide a boolean
    // flag to test whether allocations can be cast to shared
    static if (traits.allSet(AllocTrait.sharedMemory))
    {
        alias Block = shared(void)[];
    }
    else
    {
        alias Block = void[];
    }

    // Resolve @nogc attribute and shared qualifier
    static if (traits.allSet(AllocTrait.sharedInstance | AllocTrait.nogc))
    {
        @nogc shared { mixin AllocatorInterface!(); }
    }
    else static if (traits.allSet(AllocTrait.sharedInstance))
    {
        shared { mixin AllocatorInterface!(); }
    }
    else static if (traits.allSet(AllocTrait.nogc))
    {
        @nogc { mixin AllocatorInterface!(); }
    }
    else
        mixin AllocatorInterface!();
}

template IAllocator(AllocTraits traits)
{
    static if (traits.allSet(AllocTrait.sharedInstance))
        alias IAllocator = shared(IAllocatorBase!traits);
    else
        alias IAllocator = IAllocatorBase!traits;
}

// these two are here just to help test the presence of allocate() functions
private
{
    @safe @nogc nothrow pure void consumeBlock(void[]) {}
    @safe @nogc nothrow pure void consumeBlock(shared(void)[]) {}
}

private enum hasNoGCAllocate(A) =
    is(typeof(() @nogc { A* p; consumeBlock(p.allocate(1)); } ()));

private enum hasDeallocate(A) =
    is(typeof({ A* p; return p.deallocate(p.allocate(1)); } ()) : bool);
private enum hasNoGCDeallocate(A) =
    is(typeof(() @nogc { A* p; return p.deallocate(p.allocate(1)); } ()) : bool);

private enum hasDeallocateAll(A) =
    is(typeof({ A* p; return p.deallocateAll(); }()) : bool);
private enum hasNoGCDeallocateAll(A) =
    is(typeof(() @nogc { A* p; return p.deallocateAll(); }()) : bool);

private enum hasAllocateAll(A) =
    is(typeof({ A* p; return p.allocateAll(); }()) : bool);
private enum hasNoGCAllocateAll(A) =
    is(typeof(() @nogc { A* p; return p.allocateAll(); }()) : bool);

private enum hasAlignedAllocate(A) =
    is(typeof({ A* p; consumeBlock(p.alignedAllocate(1,1)); }()));
private enum hasNoGCAlignedAllocate(A) =
    is(typeof(() @nogc { A* p; consumeBlock(p.alignedAllocate(1,1)); }()));

private enum hasExpand(A) =
    is(typeof({ A* p; auto b = p.allocate(1); return p.expand(b, 2); } ()) : bool);
private enum hasNoGCExpand(A) =
    is(typeof(() @nogc { A* p; auto b = p.allocate(1); return p.expand(b, 2); } ()) : bool);

private enum hasReallocate(A) =
    is(typeof({ A* p; auto b = p.allocate(1); return p.reallocate(b, 2); } ()) : bool);
private enum hasNoGCReallocate(A) =
    is(typeof(() @nogc { A* p; auto b = p.allocate(1); return p.reallocate(b, 2); } ()) : bool);

private enum hasAlignedReallocate(A) =
    is(typeof({ A* p; auto b = p.allocate(1); return p.alignedReallocate(b, 2, 1); } ()) : bool);
private enum hasNoGCAlignedReallocate(A) =
    is(typeof(() @nogc { A* p; auto b = p.allocate(1); return p.alignedReallocate(b, 2, 1); } ()) : bool);

private enum isNoGCAllocatorImpl(A) =
    hasNoGCAllocate!A                                       &&
    (!hasDeallocate!A        || hasNoGCDeallocate!A)        &&
    (!hasDeallocateAll!A     || hasNoGCDeallocateAll!A)     &&
    (!hasAllocateAll!A       || hasNoGCAllocateAll!A)       &&
    (!hasAlignedAllocate!A   || hasNoGCAlignedAllocate!A)   &&
    (!hasExpand!A            || hasNoGCExpand!A)            &&
    (!hasReallocate!A        || hasNoGCReallocate!A)        &&
    (!hasAlignedReallocate!A || hasNoGCAlignedReallocate!A);

/// @@@TODO@@@ instead we could require `A` to provide
/// a boolean flag, i.e. `A.allocatesSharedMemory`
private enum isSharedMemAllocatorImpl(A) =
    is(typeof(() { A* p; return p.allocate(1); } ()) == shared);

/// @@@TODO@@@ test ALL primitives
private enum isSharedInstanceAllocatorImpl(A) =
    is(typeof(() { shared(A)* p; return p.allocate(1); } ()));

/// Tests if allocator implementation is @nogc
enum isNoGCAllocator(A) = anySatisfy!(isNoGCAllocatorImpl, A, shared(A));
/// Tests if allocator implementation allocates shared memory
enum isSharedMemAllocator(A) = anySatisfy!(isSharedMemAllocatorImpl, A, shared(A));
/// Tests if allocator implementation is shared
enum isSharedInstanceAllocator(A) = isSharedInstanceAllocatorImpl!A;

enum traitsOf(A : IAllocator!t, AllocTraits t) = t;

/// Tests if a concrete allocator implementation `Allocator`
/// may be represented by `IAllocator!traits`.
/// The compatibility rules are as follows:
///    - `shared` implementation may be represented by an unshared interface
///    - non-`shared` implementation may NOT be represented by a `shared` interface
///    - @nogc implementation may be represented by a non-@nogc interface
///    - non-@nogc implementation may NOT be represented by a @nogc interface
///    - shared memory allocation capability should match between
///      implementation and interface
template isAllocatorCompatible(Allocator, AllocTraits traits)
{
    static if (is(Allocator : IAllocatorBase!t, AllocTraits t))
    {
        enum isAllocatorCompatible = traits == t;
    }
    else
    {
        enum isAllocatorCompatible =
            ((isNoGCAllocator!Allocator == traits.allSet(AllocTrait.nogc)) ||
             !traits.allSet(AllocTrait.nogc)) &&
            (isSharedMemAllocator!Allocator == traits.allSet(AllocTrait.sharedMemory)) &&
            ((isSharedInstanceAllocator!Allocator == traits.allSet(AllocTrait.sharedInstance)) ||
             !traits.allSet(AllocTrait.sharedInstance));
    }
}

private enum getOverloadPrettyNames(T, string funcName) =
(){
    import std.array : join;
    string[] names;
    foreach (o; __traits(getOverloads, T, funcName))
        names ~= typeof(o).stringof;
    return names.join("\n");
}();

// Implementation details for concrete allocator classes.
// Not annotated, the class will annotate based on traits.
private mixin template AllocatorImpl()
{
    static if (is(impl)) alias ImplType = impl;
    else alias ImplType = typeof(impl);

    import std.format : format;

    override Block allocate(size_t size, TypeInfo ti)
    {
        import std.traits : hasMember;

        static if (hasMember!(ImplType, "allocate"))
        {
            static if (is(typeof(impl.allocate(size, ti)) : Block))
                return impl.allocate(size, ti);
            else static if (is(typeof(impl.allocate(size)) : Block))
                return impl.allocate(size);
            else
                static assert(0, "Incompatible allocate() signature:\n" ~
                        getOverloadPrettyNames!(ImplType, "allocate"));
        }
        else
            static assert(0, format("%s should implement allocate()",
                        ImplType.stringof));
    }

    override Block alignedAllocate(size_t size, uint alignment)
    {
        import std.traits : hasMember;

        static if (hasMember!(ImplType, "alignedAllocate"))
        {
            static if (is(typeof(impl.alignedAllocate(size, alignment)) : Block))
            {
                return impl.alignedAllocate(size, alignment);
            }
            else
                static assert(0, format("Incompatible %s.alignedAllocate() signature:\n%s",
                        ImplType.stringof,
                        getOverloadPrettyNames!(ImplType, "alignedAllocate")));
        }
        else
        {
            return null;
        }
    }

    override Block allocateAll()
    {
        import std.traits : hasMember;

        static if (hasMember!(ImplType, "allocateAll"))
        {
            static if (is(typeof(impl.allocateAll()) : Block))
            {
                return impl.allocateAll();
            }
            else
                static assert(0, format("Incompatible %s.allocateAll() signature:\n%s",
                        ImplType.stringof,
                        getOverloadPrettyNames!(ImplType, "allocateAll")));
        }
        else
        {
            return null;
        }
    }

    override bool expand(ref Block block, size_t newSize)
    {
        import std.traits : hasMember;

        static if (hasMember!(ImplType, "expand"))
        {
            // @@TODO@@@ this needs a more accurate test,
            // since expand(Block, size_t) would match
            // a silent bug
            static if (is(typeof(impl.expand(block, newSize)) : bool))
            {
                return impl.expand(block, newSize);
            }
            else
                static assert(0, format("Incompatible %s.expand() signature:\n%s",
                        ImplType.stringof,
                        getOverloadPrettyNames!(ImplType, "expand")));
        }
        else
        {
            return false;
        }
    }

    override bool reallocate(ref Block block, size_t newSize)
    {
        import std.traits : hasMember;

        static if (hasMember!(ImplType, "reallocate"))
        {
            // @@TODO@@@ this needs a more accurate test,
            // since reallocate(Block, size_t) would match
            // a silent bug
            static if (is(typeof(impl.reallocate(block, newSize)) : bool))
            {
                return impl.reallocate(block, newSize);
            }
            else
                static assert(0, format("Incompatible %s.reallocate() signature:\n%s",
                        ImplType.stringof,
                        getOverloadPrettyNames!(ImplType, "reallocate")));
        }
        else
        {
            return false;
        }
    }

    override bool alignedReallocate(ref Block block, size_t newSize, uint alignment)
    {
        import std.traits : hasMember;

        static if (hasMember!(ImplType, "alignedReallocate"))
        {
            // @@TODO@@@ this needs a more accurate test,
            // since alignedReallocate(Block, size_t) would match
            // a silent bug
            static if (is(typeof(impl.alignedReallocate(block, newSize, alignment)) : bool))
            {
                return impl.alignedReallocate(block, newSize, alignment);
            }
            else
                static assert(0, format("Incompatible %s.alignedReallocate() signature:\n%s",
                        ImplType.stringof,
                        getOverloadPrettyNames!(ImplType, "alignedReallocate")));
        }
        else
        {
            return false;
        }
    }

    override bool deallocate(Block block)
    {
        import std.traits : hasMember;

        static if (hasMember!(ImplType, "deallocate"))
        {
            static if (is(typeof(impl.deallocate(block)) : bool))
            {
                return impl.deallocate(block);
            }
            else
                static assert(0, format("Incompatible %s.deallocate() signature:\n%s",
                        ImplType.stringof,
                        getOverloadPrettyNames!(ImplType, "deallocate")));
        }
        else
        {
            return false;
        }
    }

    override bool deallocateAll()
    {
        import std.traits : hasMember;

        static if (hasMember!(ImplType, "deallocateAll"))
        {
            static if (is(typeof(impl.deallocateAll()) : bool))
            {
                return impl.deallocateAll();
            }
            else
                static assert(0, format("Incompatible %s.deallocateAll() signature:\n%s",
                        ImplType.stringof,
                        getOverloadPrettyNames!(ImplType, "deallocateAll()")));
        }
        else
        {
            return false;
        }
    }

//@nogc:

    override @property uint alignment() const
    {
        return impl.alignment;
    }

    override size_t goodAllocSize(size_t s) const
    {
        return impl.goodAllocSize(s);
    }

    override Ternary owns(Block block) const
    {
        import std.traits : hasMember;

        static if (hasMember!(ImplType, "owns"))
        {
            static if (is(typeof(Ternary(impl.owns(block)))))
            {
                return Ternary(impl.owns(block));
            }
            else
                static assert(0, format("Incompatible %s.owns() signature:\n%s",
                        ImplType.stringof,
                        getOverloadPrettyNames!(ImplType, "owns")));
        }
        else
        {
            return Ternary.unknown;
        }
    }

    override Ternary resolveInternalPointer(void* p, ref Block result) const
    {
        import std.traits : hasMember;

        static if (hasMember!(ImplType, "resolveInternalPointer"))
        {
            // @@TODO@@@ this needs a more accurate test,
            // since resolveInternalPointer(void*, Block) would match:
            // a silent bug
            static if (is(typeof(impl.resolveInternalPointer(p, result)) : Ternary))
            {
                return impl.resolveInternalPointer(p, result);
            }
            else
                static assert(0, format("Incompatible %s.resolveInternalPointer() signature:\n%s",
                        ImplType.stringof,
                        getOverloadPrettyNames!(ImplType, "resolveInternalPointer")));
        }
        else
        {
            return Ternary.unknown;
        }
    }

    override @property Ternary empty() const
    {
        import std.traits : hasMember;

        static if (hasMember!(ImplType, "empty"))
        {
            static if (is(typeof(Ternary(impl.empty))))
            {
                return Ternary(impl.empty);
            }
            else
                static assert(0, format("Incompatible %s.empty() signature:\n%s",
                        ImplType.stringof,
                        getOverloadPrettyNames!(ImplType, "empty")));
        }
        else
        {
            return Ternary.unknown;
        }
    }

}

/// Creates an interface for accessing concrete allocator implementation.
/// If `A` is already an instance of `IAllocator!traits`, simply returns
/// `allocator`.
/// Otherwise copies (or moves, if `A` is not copiable) or aliases
/// (if `A` has no state) the implementation `allocator` and returns
/// an instance of `IAllocator!traits` that forwards calls to `allocator`.
/// @@@TODO@@@: allocator passed by pointer
IAllocator!traits allocatorObject(AllocTraits traits, A)(auto ref A allocator)
{
    // @@@TODO@@@: better error messages
    static if (is(A : IAllocatorBase!traits))
    {
        return allocator;
    }
    else
    {
        static assert(isAllocatorCompatible!(A,traits), "Incompatible allocator type");

        static class CAllocator : IAllocatorBase!traits
        {
            static if (isSharedInstanceAllocator!A)
                alias Impl = shared(A);
            else
                alias Impl = A;
            /*@@@TODO@@@: indirect */
            static if (stateSize!Impl) Impl impl;
            else alias impl = Impl.instance;

            // Resolve @nogc attribute and shared qualifier
            static if (traits.allSet(AllocTrait.sharedInstance | AllocTrait.nogc))
            {
                @nogc shared { mixin AllocatorImpl!(); }
            }
            else static if (traits.allSet(AllocTrait.sharedInstance))
            {
                shared { mixin AllocatorImpl!(); }
            }
            else static if (traits.allSet(AllocTrait.nogc))
            {
                @nogc { mixin AllocatorImpl!(); }
            }
            else
                mixin AllocatorImpl!();
        }

        static if (traits.allSet(AllocTrait.sharedInstance))
            alias Allocator = shared(CAllocator);
        else
            alias Allocator = CAllocator;

        import std.functional : forward;
        import std.conv : emplace;
        import std.traits : classInstanceAlignment;

        static if (stateSize!A == 0)
        {
            static struct State
            {
                // @@@TODO@@@ this fails with LDC 1.1.1 (expects constant),
                // need to test with newer versions
                align(classInstanceAlignment!Allocator)
                void[stateSize!Allocator] block;
            }
            static __gshared State state;
            static __gshared Allocator result;
            if (!result)
            {
                result = emplace!Allocator(state.block[]);
            }
            assert(result);
            return result;
        }
        else static if (is(typeof({ A* p; A b = *p; })))
        {
            // Copy
            static if (is(typeof({ allocator.alignedAllocate(
                                stateSize!Allocator,
                                classInstanceAlignment!Allocator); })))
            {
                auto state = allocator.alignedAllocate(
                        stateSize!Allocator,
                        classInstanceAlignment!Allocator);
            }
            else
            {
                auto state = allocator.allocate(stateSize!Allocator);
            }
            static if (is(typeof({ allocator.deallocate(state); }) : bool))
            {
                scope (failure) allocator.deallocate(state);
            }
            assert(state.ptr.isAligned(classInstanceAlignment!Allocator));
            return cast(Allocator) emplace!Allocator(state);
        }
        else
        {
            // Allocate on stack and move
            static struct State
            {
                // @@@TODO@@@ this fails with LDC 1.1.1 (expects constant),
                // need to test with newer versions
                align(classInstanceAlignment!Allocator)
                void[stateSize!Allocator] block;

                ~this() @nogc nothrow
                {
                    import core.stdc.string : memset;
                    memset(block.ptr, 0, block.length);
                }
            }
            State state;
            import std.algorithm.mutation : move;
            static if (is(typeof({ allocator.alignedAllocate(
                                stateSize!Allocator,
                                classInstanceAlignment!Allocator); })))
            {
                auto dynState = allocator.alignedAllocate(
                        stateSize!Allocator,
                        classInstanceAlignment!Allocator);
            }
            else
            {
                auto dynState = allocator.allocate(stateSize!Allocator);
            }
            static if (is(typeof({ allocator.deallocate(dynState); }) : bool))
            {
                scope (failure) allocator.deallocate(dynState);
            }
            assert(dynState.ptr.isAligned(classInstanceAlignment!Allocator));
            emplace!Allocator(state.block[], move(allocator));
            dynState[] = state.block[];
            return cast(Allocator) dynState.ptr;
        }
    }
}

import std.experimental.allocator.gc_allocator;

// @@@TODO@@@ processAllocator should also include AllocTrait.sharedMemory
enum processAllocatorTraits = AllocTraits(AllocTrait.sharedInstance);
enum threadAllocatorTraits = AllocTraits.init;

private
{
    IAllocator!processAllocatorTraits processAllocator_;
    IAllocator!threadAllocatorTraits threadAllocator_;
}

unittest
{
    static assert(is(typeof(processAllocator_) == shared));
    static assert(!is(typeof(threadAllocator_) == shared));
}

unittest
{
    static assert(!isAllocatorCompatible!(typeof(theAllocator), processAllocatorTraits));
    static assert(!isAllocatorCompatible!(typeof(processAllocator), threadAllocatorTraits));
}

shared static this()
{
    assert(!processAllocator_);
    processAllocator_ = allocatorObject!processAllocatorTraits(GCAllocator.instance);
}

static this()
{
    assert(!threadAllocator_);
    threadAllocator_ = allocatorObject!threadAllocatorTraits(GCAllocator.instance);
}

@nogc @safe nothrow @property
IAllocator!threadAllocatorTraits theAllocator()
{
    return threadAllocator_;
}

@nogc @safe nothrow @property
void theAllocator(IAllocator!threadAllocatorTraits a)
{
    assert(a);
    threadAllocator_ = a;
}

@nogc @safe nothrow @property
IAllocator!processAllocatorTraits processAllocator()
{
    return processAllocator_;
}

@nogc @safe nothrow @property
void processAllocator(IAllocator!processAllocatorTraits a)
{
    assert(a);
    processAllocator_ = a;
}

version (unittest) import std.experimental.allocator.mallocator;

// Use @nogc shared Mallocator as a non-@nogc unshared theAllocator
unittest
{
    auto old = theAllocator;
    scope(exit) theAllocator = old;
    theAllocator = allocatorObject!threadAllocatorTraits(Mallocator.instance);
    auto block = theAllocator.allocate(1);
    assert(block);
    theAllocator.deallocate(block);
}

// Use @nogc shared Mallocator as a non-@nogc shared processAllocator
unittest
{
    auto old = processAllocator;
    scope(exit) processAllocator = old;
    processAllocator = allocatorObject!processAllocatorTraits(Mallocator.instance);
    auto block = processAllocator.allocate(1);
    assert(block);
    processAllocator.deallocate(block);
}

unittest
{
    auto ptr = theAllocator.make!int(42);
    assert(ptr && *ptr == 42);
    theAllocator.dispose(ptr);
}

unittest
{
    auto ptr = processAllocator.make!int(42);
    assert(ptr && *ptr == 42);
    processAllocator.dispose(ptr);
}
