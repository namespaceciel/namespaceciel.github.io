---
layout: post
title: C++ noexcept 有何奇用之 GNU libstdc++ unordered 容器的天才与逆天并存的哈希表内存布局设计
header-img: img/village3.JPG
header-style: text
catalog: true
tags:
  - C++
  - 哈希表
  - noexcept
---

![图片](/img/village3.JPG)

本文参考自 Arthur O'Dwyer 的博客：[https://quuxplusone.github.io/blog/2024/08/16/libstdcxx-noexcept-hash/](https://quuxplusone.github.io/blog/2024/08/16/libstdcxx-noexcept-hash/)
{:.info}

## 0. 标准库 unordered 容器简介

标准库的四个容器：`std::unordered_set`、`std::unordered_map`、`std::unordered_multiset` 和 `std::unordered_multimap` 的底层都是同一个东西：哈希表。它具体类似一个邻接链表：一个链表数组，我们对类型 `T` 的对象哈希之后，将哈希值对着数组长度取模，就得到了它应该存放的“桶”，然后作为一个链表结点挂在那个桶上。

正式来说，同一个桶上的结点的哈希值对数组长度取模一定相等，而它们的哈希值并不一定相同；如果它们的哈希值相同，也并不一定代表它们的值相同（根据 `operator==` 确定）。不过这个关系反向都成立。

而计算哈希值这个操作贯穿了哈希表的几乎所有操作：不管我们要插入、删除或是查找结点，我们都首先需要根据 key 拿到结点哈希值，计算出它所在的桶。为什么不直接把所有结点查找一遍呢，因为哈希表有一个重要的指标叫做 `load_factor`，它指的是哈希表的结点数除以数组长度，这个值一般取 0.5 - 1 比较多，也就是说在哈希策略不太差的情况下，几乎每个桶上都最多只有一个结点，所以是否根据哈希值先定位到桶就是 O(n) 与 O(1) 的区别。

并且当哈希表不断插入元素，当前的 `load_factor` 超过了设定值之后，哈希表会进行重哈希：计算出下一个更大质数的数组长度，将原来的结点重新挂到这个新数组上，这个过程也需要所有结点的哈希值。

不过本文牵涉到的最重要的一个函数其实是 `erase(iterator pos)`，即当我们已经有某个结点的迭代器了，直接对其删除。这个看似最简单的操作实际上也需要计算结点哈希值，因为 libc++ 与 libstdc++ 的哈希表实现都是单链表，只有当前结点的迭代器无法更新上一个迭代器的 `next`，所以导致它依旧需要结点哈希值来对那个桶进行一次遍历来找到上一个结点。（MSVC STL 的链表倒确实是双链表）

## 1. 存储哈希值 or 每次都计算一遍哈希值

所以有这么多需要结点哈希值的地方，这个哈希值怎么处理呢。libc++ 是直接把哈希值存储在了结点中，免去了重复计算哈希值可能导致的性能问题，代价是每个结点都要多分配 8 字节用来存放一个 `size_t` 值。这个策略对于很多简单类型实际上是比较浪费的，拿 `int` 举例，它的哈希值就是它本身，而我们为了 4 字节的类型多花了 8 字节来存放一个没有意义的数据。

所以如果它能默认存储哈希值，但我们有办法对于具体类型来决定是否不存储，岂不是两全其美了。

libstdc++ 真给了我们这个选择，但是逻辑却是完全反的！默认情况下它永远不会存储哈希值，只有满足了两个条件时它才会存储：

```cpp
template<typename _Tp, typename _Hash>
using __cache_default
    =  __not_<__and_<// Do not cache for fast hasher.
            __is_fast_hash<_Hash>,
            // Mandatory for the rehash process.
            __is_nothrow_invocable<const _Hash&, const _Tp&>>>;
```

第一个条件是一个内部类 `__is_fast_hash`，它默认情况下是 true，然后对 `long double` 与 `std::string` 等哈希代价较大的类型再特化成了 false。当然不建议用户在任何情况下对这种特定标准库实现的隐藏类做特化。

第二个条件则是本文的标题所述，它会检查哈希函数对类型 T 的哈希是否是 `noexcept` 的，即是否保证不抛出异常。注意到上节所述的 `erase(iterator pos)`，标准保证这个函数是不抛出异常的，但如果哈希函数不标 `noexcept`，那这个函数就不被允许调用哈希函数。在这一串原因下，哈希表只能选择在结点中存储它的哈希值。

总结：如果用户将 libstdc++ 作为标准库并且使用 unordered 容器，唯一决定 ta 的自定义类型 `T` 是否被哈希表结点存储哈希值的唯一途径就是哈希函数是否标 `noexcept`。

libstdc++ 这种行为在我看来就是天才与逆天并存，因为 `noexcept` 与是否存储哈希值在逻辑上并无直接关联，正常人压根不会想到它们会有联系。而大多数没有认真看过 GNU 文档或者读过 libstdc++ 源码的人，根本就没机会知道这件事。

## 2. 改变 libstdc++ 标记类型的行为

之前说过 libstdc++ 通过 `__is_fast_hash` 对于一些标准库类型做过特化，但是他们没有意识到哈希 `std::vector<bool>` 很慢，而默认选择了不存储哈希值。为了改变这个问题，我们最好自己定义一个不标 `noexcept` 的 `std::vector<bool>` 哈希函数来强行让它存储哈希值。

## 3. 逸闻

Bitcoin Core 是现实中确实被这个逆天设定坑过的项目。它有一个巨大的 Bitcoin 类型哈希表，这个类型的哈希值计算非常简单，但是由于他们没有为哈希函数标记 `noexcept`，导致超大数量的 Bitcoin 结点每个都浪费了 8 字节内存。

之后他们在这个 [commit](https://github.com/bitcoin/bitcoin/commit/67d99900b0d770038c9c5708553143137b124a6c) 中，通过标记了 `noexcept`，使性能损失了 1.6%，但是省下了 9.4% 的内存开销，这使得内存布局更加紧凑，数据库缓存更加友好，对于他们这个系统而言是非常有利的。
