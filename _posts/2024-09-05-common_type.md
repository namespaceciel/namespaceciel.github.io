---
layout: post
title: C++ 模板元编程入门之 std::common_type 的实现
header-img: img/flower.png
header-style: text
catalog: true
tags:
  - C++
  - 模板元编程
---

![图片](/img/flower.png)

本文前置知识见 [C++ SFINAE 简单介绍与两个常用用法](https://namespaceciel.github.io/2024/09/04/SFINAE/)
{:.info}

`std::common_type` 意为取得多个类型的公共类型（即可以容得下原类型们的值的类型）。

比如 `int` 与 `long long` 的公共类型为 `long long`，而 `double` 和 `long long` 的公共类型则为 `double`。

```cpp
static_assert(std::is_same_v<std::common_type_t<int, long long>, long long>);
static_assert(std::is_same_v<std::common_type_t<double, long long>, double>);
```

它在标准库一些函数，例如 C++17 的 `std::gcd` 中有重要作用：

```cpp
template<class M, class N>
constexpr std::common_type_t<M, N> gcd(M m, N n);
```

具体实现可参考 [std::common_type - cppreference.com](https://zh.cppreference.com/w/cpp/types/common_type)，本文由此介绍具体的两个细节。

## 1. 三元运算符拿到公共类型

三元运算符有一个非常重要的作用，就是

```cpp
condition ? res1 : res2
```

的结果类型是 `res1` 和 `res2` 的公共类型，且是编译期确定，与这里的 `condition` 求值结果无关。

三元运算符具体知识见 [其他运算符 - cppreference.com](https://zh.cppreference.com/w/cpp/language/operator_other) 条件运算符 小节。

所以 `common_type` 的雏形只需要如下实现：

```cpp
template<class T1, class T2>
using common_type_t = decltype(true ? std::declval<T1>() : std::declval<T2>());
```

这里的 `std::declval<T>()` 拿到一个类型的右值引用，使得在 `decltype` 说明符的操作数中不必经过构造函数就能使用成员函数，只能用于不求值语境。

## 2. std::common_type 具体实现介绍

如 [std::common_type - cppreference.com](https://zh.cppreference.com/w/cpp/types/common_type) 所示：

```cpp
1. 如果 sizeof...(T) 是零，那么无成员 type。
2. 如果 sizeof...(T) 是一（即 T... 只含一个类型 T0），那么成员 type 指名与 std::common_type<T0, T0>::type 相同的类型，如果存在；否则没有成员 type。
3. 如果 sizeof...(T) 是二（即 T... 正好包含两个成员 T1 和 T2），那么：
  (1) 如果应用 std::decay 到 T1 与 T2 中至少一个类型后产生了不同的类型，那么成员 type 指名与 std::common_type<std::decay<T1>::type, std::decay<T2>::type>::type 相同的类型（如果存在）；不存在时没有成员 type。
  (2) 否则，如果有对 std::common_type<T1, T2> 的用户定义特化，那么使用该特化。
  (3) 否则，如果 std::decay<decltype(false ? std::declval<T1>() : std::declval<T2>())>::type 是合法类型，那么成员 type 代表该类型，参见条件运算符。
  (4) 否则，如果 std::decay<decltype(false ? std::declval<CR1>() : std::declval<CR2>())>::type 是合法类型，其中 CR1 与 CR2 分别是 const std::remove_reference_t<T1>& 与 const std::remove_reference_t<T2>&，那么成员 type 代表该类型。(C++20 起)
  (5) 否则，没有成员 type。
4. 如果 sizeof...(T) 大于二（即 T... 由类型 T1, T2, R... 组成），那么 std::common_type<T1, T2>::type 存在时成员 type 指代 std::common_type<std::common_type<T1, T2>::type, R...>::type（如果存在这种类型）。其他所有情况下，没有成员 type。
```

`std::common_type` 具体规则则稍微复杂一点，原因是要给予程序员更多的自定义空间，比如在使用三元运算符之前会先查看是否有用户定义了特化，优先使用特化。

`sizeof...(T) == 1` 时还要用 `std::common_type<T0, T0>` 走一遍主流程也是为了这个。

## 3. 一个分类小技巧

可以看到具体定义中出现了“如果满足 A 条件，则用 a，否则如果满足 B 条件，则用 b，否则 ...”的规则，对于这种的实现如果用 n 层 `std::conditional` 会显得非常丑陋，这里介绍一种非常优雅的写法：

```cpp
// 主模板，作为 SFINAE 的 backup
template<class T1, class T2, class = void> struct common_type_sub_bullet4 {};
template<class T1, class T2, class = void> struct common_type_sub_bullet3 : common_type_sub_bullet4<T1, T2> {};
template<class T1, class T2, class = void> struct common_type_sub_bullet2 : common_type_sub_bullet3<T1, T2> {};
template<class T1, class T2, class = void> struct common_type_sub_bullet1 : common_type_sub_bullet2<T1, T2> {};

// 对每个 bullet 定义偏特化
template<class T1, class T2>
struct common_type_sub_bullet1<T1, T2, typename std::enable_if<A>::type> {
    using type = a;
};

template<class T1, class T2>
struct common_type_sub_bullet2<T1, T2, typename std::enable_if<B>::type> {
    using type = b;
};

template<class T1, class T2>
struct common_type_sub_bullet3<T1, T2, typename std::enable_if<C>::type> {
    using type = c;
};

template<class T1, class T2>
struct common_type_sub_bullet4<T1, T2, typename std::enable_if<D>::type> {
    using type = d;
};

// 真正使用的类
template<class T1, class T2>
struct common_type_helper<T1, T2> : common_type_sub_bullet1<T1 ,T2> {};
```

主模板继承顺序为 `common_type_helper` 继承 `bullet1` 继承 `bullet2`...

这里的偏特化用 `typename std::enable_if<Condition>::type` 尝试取得 `Condition` 为真时才有的 `type` `void`，满足主模板的第三参数 `class = void`。

所以 `Condition` 成立时就有了 `type`，不成立时就回退到主模板，没有 `type`。

所以如果 `A` 条件满足，那么 `bullet1` 类内已经有 `type` 了，且它偏特化模板不继承 `bullet2`，直接结束。

而如果 `A` 条件不满足，那么 `bullet1` 则是一个空类，继承了 `bullet2`。重复这个流程直到找到首个满足条件的 `bullet`，拿到它的 `type`。

当然这里就算偏特化模板里像主模板一样定义了继承关系，也没有任何影响，因为如果一个类重复继承同一个 `type`，那么 `type` 会依次被覆盖，最后存留的只会是最下层的 `type`。

所以如果 `A` 条件满足，那么 `bullet1` 类内已经有 `type` 了，那它就算继承的上层 `type` 还存在多个，都会被自己的 `type` 覆盖，不需要管。
