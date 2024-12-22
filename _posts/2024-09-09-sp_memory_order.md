---
layout: post
title: C++ 从 std::shared_ptr 引用计数的实现浅析 std::memory_order
header-img: img/villlage2.JPG
header-style: text
catalog: true
tags:
  - C++
  - memory_order
---

![图片](/img/villlage2.JPG)

本文前置知识见 [[C++] 一点点 std::shared_ptr 的实现细节](https://www.bilibili.com/video/BV1wx421X72W)
{:.info}

## 1. 开篇

文档可见：[std::memory_order - cppreference.com](https://zh.cppreference.com/w/cpp/atomic/memory_order)

首先我们需要知道，当我们写下如下的代码时，最后编译成汇编并不一样会是我们想象的那样：

```cpp
void f() {
    int a = 1;
    double b = 1.0;
}
```

以此例来说，编译器完全可以把两条指令的执行顺序倒转。当然不止如此，在 RISC 平台上，由于在内存写入一个变量需要 load 入寄存器，修改值，再 store 回内存，所以这里可以拆成六条指令。只要它们在**单线程**下的执行结果不变，编译器可以随意调整它们的执行顺序，以追求更高效的指令执行。

但是到了多线程，这个指令重排行为就会带来很多麻烦。如果大家学过设计模式里单例模式的历史，可以知道单例模式里面的懒汉模式，在过去几十年一直是有 bug 的。在 C++ 里直到 C++11 标准引入 `std::memory_order` 才真正可以进行多线程编程。

## 2. 六种 memory_order

当我们使用 `std::atomic<size_t>` 作为 `std::shared_ptr` 引用计数时，很多人可以会像操作普通整型值一样进行 `++` `+=` 等操作，这样虽然没有任何安全性问题，但是会比较浪费性能，因为 `++` 实际上是 `fetch_add(1, std::memory_order_seq_cst)` 的重载（其它操作同理），而 `std::memory_order_seq_cst` 是六种 memory_order 中最强也是性能损失最大的一种，多数情况下并没有必要。

而最弱的为 `std::memory_order_relaxed`，只保证原子性，没有同步或定序约束。**引用计数中的增加只需要使用它即可。**

`std::memory_order_acquire` 指的是从此语句往下的指令不允许重排到此语句之前，而 `std::memory_order_release` 则是从此语句往上的指令不允许重排到此语句之后。`std::memory_order_acq_rel` 是它们的加和。**这是本篇要探讨的核心。**

`std::memory_order_consume` 则是一个非常特殊且少用的东西，大部分人并不需要了解。注意到文档中有讲到 2015 年 2 月为止没有任何已知产品级编译器跟踪依赖链：consume 均被实现为 acquire。并且 C++17 中提到释放消费定序的规范正在修订中，暂时不鼓励使用 `std::memory_order_consume`。

## 3. 释放-获取定序

### 先以 cppreference 的小例子讲解一下

```cpp
std::atomic<std::string*> ptr;
int data;
 
void producer() {
    std::string* p = new std::string("Hello");
    data = 42;
    ptr.store(p, std::memory_order_release);
}
 
void consumer() {
    std::string* p2;
    while (!(p2 = ptr.load(std::memory_order_acquire))) {}
    assert(*p2 == "Hello");
    assert(data == 42);
}
```

这个例子中，从人类视角设想的场景应该是：消费者线程一直卡在 `while` 循环，直到生产者执行完更新 `ptr` 那一行。此时 `p` 和 `data` 已经赋值过了，`assert` 语句不会有问题。得益于这一对 `std::memory_order_release` `std::memory_order_acquire`，执行确实会如预期所示。

但如果我们将生产者的 `std::memory_order_release` 替换为 `std::memory_order_relaxed`，情况就可能不一样了。失去了 `release` “从此语句往上的指令不允许重排到此语句之后”的保证，对 `p` 和 `data` 的赋值指令都有可能在 `store` 后才执行。

你可能会有疑问，`data` 重排没问题，因为在单线程下确实在哪里执行都不影响正确结果，但 `p` 会被 `store` 进 `ptr`，它不应该一定要被执行完吗？并不一定，因为 `new` 也分为：用 `::operator new(sizeof(std::string))` 分配内存返回一根指针，在这根指针上执行 `std::string` 的构造函数（如果构造函数抛出异常还会 `::operator delete` 这块内存），然后再把指针赋值给 `p`。这个过程也可以随意被重排，所以这个指针先赋值给 `p` 后再执行构造函数也完全可以，而 `ptr` 拿到 `p` 以后消费者查看 `*p2` 的时候这个构造函数可能还没有完成呢。这也是之前提到的懒汉单例模式的远古 bug。

那我们将消费者的 `std::memory_order_acquire` 替换为 `std::memory_order_relaxed` 又会如何呢。那它完全可以在 `while` 之前就取得 `data` 的值存入寄存器，只不过延迟到 `while` 之后才 `assert`，那使用的仍是未初始化值。

### `std::shared_ptr` 的引用计数

```cpp
void shared_count_release() noexcept {
    // A decrement-release + an acquire fence is recommended by Boost's documentation:
    // https://www.boost.org/doc/libs/1_57_0/doc/html/atomic/usage_examples.html
    // Alternatively, an acquire-release decrement would work, but might be less efficient
    // since the acquire is only relevant if the decrement zeros the counter.
    if (shared_count_.fetch_sub(1, std::memory_order_release) == 1) {
        std::atomic_thread_fence(std::memory_order_acquire);

        delete_pointer();
        weak_count_release(); // weak_count_ == weak_ref + (shared_count_ != 0)
    }
}
```

`std::weak_ptr` 的 `weak_count_release()` 实现同理。

这里还是举两个反例来分别说明 `fetch_sub(1, std::memory_order_release)` 和 `std::atomic_thread_fence(std::memory_order_acquire)` 的必要性。

这里的场景是当引用计数减为 0 时，最后那个线程要执行 `if` 块里的清理收尾过程。但是注意这里 `fetch_sub` 如果没有释放定序，之前对于管理对象的各种操作就可以重排到 `if` 块之后。只要引用计数不减到 0，那么对于当前线程来说，只是对一个数做了一次自减而已，自减在什么时候做都是一样的。而只要与此同时有另一个线程把引用计数减到 0 同时进行析构释放操作，之前这个线程就崩了。

说到 `std::atomic_thread_fence(std::memory_order_acquire)` 需要举一个稍微刁钻的例子：

假设我们的 `std::shared_ptr` 的管理对象为 `std::unique_ptr<int>`，我们知道它的析构会是把内部的指针 `delete`。

```cpp
std::shared_ptr<std::unique_ptr<int>> sp{new std::unique_ptr<int>{new int{1}}}; // 初始构造了一个 up 值为 1，sp 被两个线程持有

// 某个线程做了这样的事
sp.get()->reset(new int{2}); // reset 会删除之前管理的 up，并且塞入一个新的 up 值为 2

// 两个线程都调用了 shared_count_release()
if (shared_count_.fetch_sub(1, std::memory_order_release) == 1) {
    // std::atomic_thread_fence(std::memory_order_acquire);
    ...
}
```

所以在 `if` 块中会执行析构，并且把 `sp` 里面的 `up` 删除。而没有这个 `acquire`，编译器可以选择在 `if` 语句之前就把要删的 `up` 的指针提前存入寄存器，之后直接删除寄存器里的指针值。所以可以出现这样的场景：线程 1 向寄存器中存入了值为 1 的 `up` 值等待删除，而线程 2 中途又把 `up` 换掉了。那最后的结果就变成了 `up1` 被 double free 而 `up2` 泄漏。

### libc++ 优化

LLVM 对于 `weak_count_release()` 有进一步的优化：

```cpp
void weak_count_release() noexcept {
    // Avoid expensive atomic stores inspired by LLVM:
    // https://github.com/llvm/llvm-project/commit/ac9eec8602786b13a2bea685257d4f25b36030ff
    if (weak_count_.load(std::memory_order_acquire) == 1) {
        delete_control_block();

    } else if (weak_count_.fetch_sub(1, std::memory_order_release) == 1) {
        std::atomic_thread_fence(std::memory_order_acquire);
        delete_control_block();
    }
}
```

也就是在之前的基础上先 `acquire load` 查看值是否为 1，如果是 1 就代表它已经是最后一个持有资源的 `std::weak_ptr`，我们就可以直接删除资源，省下将引用计数更新为 0 写回内存的操作，因为 `atomic store` 开销还是比较大的。**注意这里 `acquire load` 跟其它线程潜在的 `fetch_sub(1, std::memory_order_release)` 依旧构成释放-获取定序**，所以不会有指令重排的风险。

但是，当最后一个持有资源的线程准备释放它时，这段时间依旧可以有其它线程尝试访问它并且增加引用计数。这句话是没错，问题在于，即使没有这个优化，这个访问过程也依旧可以发生在资源释放过程中的任何时刻，所以无论如何这都是无法避免的问题。

实际上这也确实不是 `sp` 和 `wp` 的责任，而是 `std::atomic<std::shared_ptr<T>>` 和 `std::atomic<std::weak_ptr<T>>` 的责任，因为 `sp` 和 `wp` 本来就不是线程安全的。

再说回这个优化，它不能用于 `shared_count_release()` 是因为对于 `std::shared_ptr`，还存在一个特殊的函数 `lock()` 会原子性地检查 `shared_count_` 的值，如果为 0 就认为其已被释放而不做任何事，不为 0 则从中增加一个引用共享，所以更新为 0 是必要的。而 `std::weak_ptr` 则没有。
