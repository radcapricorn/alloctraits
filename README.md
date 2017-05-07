# alloctraits
D allocators with traits

# Rationale
Existing `std.experimental.allocator` package offers a `IAllocator` interface
for allocator type erasure. Unfortunately, due to its' design, `IAllocator`
short circuits any compile-time inference for attributes and qualifiers, making
it unsuitable for generic code:

```D
import std.experimental.allocator;

struct Collection(T)
{
    IAllocator allocator_;
    void[] memory_;

    this(Args...)(IAllocator a, auto ref Args args)
    {
        allocator_ = a;
        memory_ = allocator_.allocate(T.sizeof*args.length);
        // ...
    }
}

void main()
{
    import std.experimental.allocator.mallocator;

    // Even though Mallocator does provide @nogc methods,
    // and its' instance is in fact `shared`, IAllocator
    // consumes this information and Collection does not benefit from it
    auto collection = Collection!int(allocatorObject(Mallocator.instance));
}

// this test will not compile:
@nogc unittest
{
    auto collection = Collection!int(allocatorObject(Mallocator.instance));
}
```

The `Collection` cannot provide @nogc guarantees, or expect IAllocator to be
shared.

# Proposed solution
Instead of a narrow `IAllocator` interface, introduce a `IAllocator!traits`
interface, that would type it's methods in accordance to provided traits, and
make sure that concrete allocator implementations are compatible with requested
traits:

```D
import ext.allocator;

struct Collection(T, AllocTraits traits = AllocTraits.none)
{
    IAllocator!traits allocator_;
    void[] memory_;

    this(Args...)(IAllocator!traits a, auto ref Args args)
    {
        allocator_ = a;
        memory_ = allocator_.allocate(T.sizeof*args.length);
        // ...
    }
}

void main()
{
    import std.experimental.allocator.mallocator;

    // with the proposed design, IAllocator!traits
    // will preserve @nogc information
    enum AllocTraits traits = AllocTraits.nogc;
    auto collection = Collection!(int, traits)(allocatorObject!traits(Mallocator.instance));
}

// this test will compile:
@nogc unittest
{
    enum AllocTraits traits = AllocTraits.nogc;
    auto collection = Collection!(int, traits)(allocatorObject!traits(Mallocator.instance));
}

// this will not compile, as GCAllocator is not @nogc
@nogc unittest
{
    import std.experimental.allocator.gc_allocator;
    enum AllocTraits traits = AllocTraits.nogc;
    auto collection = Collection!(int, traits)(allocatorObject!traits(GCAllocator.instance));
}
```
