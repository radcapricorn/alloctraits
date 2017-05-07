module collection;

import ext.allocator;

/// Hypothetical collection (only ctor and dtor are provided for testing).
/// Instead of parametrizing by concrete allocator implementation,
/// we parametrize by traits.
/// At initialization, allocatorObject() will make sure that
/// the concrete implementation is compatible with the specified traits,
/// and if it's not, a compile-time error will be issued
struct Collection(T, AllocTraits allocTraits = AllocTraits.init)
{
    IAllocator!allocTraits allocator_;
    T[] data_;

    // Alternatively, the ctor might take IAllocator!allocTraits
    // explicitly
    this(A,Args...)(auto ref A allocator, auto ref Args args)
        if (isAllocatorCompatible!(A,allocTraits))
    {
        import std.functional : forward;
        allocator_ = allocatorObject!allocTraits(forward!allocator);

        import std.conv : emplace;
        // behave like an array for testing purposes
        auto block = allocator_.allocate(T.sizeof*args.length);
        data_ = cast(T[])block;
        foreach(i, _; Args)
            emplace(&data_[i], forward!(args[i]));
    }

    ~this()
    {
        // ... (snipped) call dtors, etc ...

        // 'this' could've been moved
        if (allocator_)
        {
            allocator_.deallocate(data_);
        }
    }
}

import std.experimental.allocator.mallocator;
import std.experimental.allocator.gc_allocator;

// No tests for shared memory allocation at the moment
// as existing allocators lack support for it

// Collection that doesn't put any requirements on allocator
// can use a GCAllocator
unittest
{
    static assert(is(typeof(Collection!int(GCAllocator.instance))));
}

// Mallocator is shared and @nogc,
// can degrade to unshared and non-@nogc interface
unittest
{
    static assert(is(typeof(Collection!int(Mallocator.instance))));
}

// Can use Mallocator for Collection that requires a @nogc allocator
unittest
{
    enum AllocTraits traits = AllocTrait.nogc;
    static assert(is(typeof(Collection!(int, traits)(Mallocator.instance))));
}

// Can use Mallocator for Collection that requires a @nogc shared allocator
unittest
{
    enum AllocTraits traits = AllocTrait.nogc | AllocTrait.sharedInstance;
    static assert(is(typeof(Collection!(int, traits)(Mallocator.instance))));
}

// Should also be possible to use Mallocator for shared memory allocations,
// but the introspection is not implemented at the moment
version(none)
unittest
{
    enum AllocTraits traits = AllocTrait.sharedMemory;
    static assert(is(typeof(Collection!(int, traits)(Mallocator.instance))));
}

// Cannot instantiate @nogc Collection with a GCAllocator
unittest
{
    enum AllocTraits traits = AllocTrait.nogc;
    static assert(!is(typeof(Collection!(int, traits)(GCAllocator.instance))));
}

// Default Collection expects unshared interface,
// so it can't be instantiated with processAllocator,
// but can be with theAllocator
unittest
{
    static assert(!is(typeof(Collection!int(processAllocator))));
    static assert(is(typeof(Collection!int(theAllocator))));
}

// Collection expecting shared interface may be instantiated
// with processAllocator, but not with theAllocator
unittest
{
    enum AllocTraits traits = AllocTrait.sharedInstance;
    static assert(is(typeof(Collection!(int, traits)(processAllocator))));
    static assert(!is(typeof(Collection!(int, traits)(theAllocator))));
}

// Test allocation with default traits
unittest
{
    auto c = Collection!int(theAllocator, 6, 7, 8, 9, 0);
    int[5] expected = [ 6, 7, 8, 9, 0 ];
    assert(c.data_ == expected);
}

// Test allocation and @nogc inference
@nogc unittest
{
    enum traits = AllocTraits(AllocTrait.nogc);
    auto c = Collection!(int, traits)(Mallocator.instance, 1, 2, 3, 4, 5);
    int[5] expected = [ 1, 2, 3, 4, 5 ];
    assert(c.data_ == expected);
}
