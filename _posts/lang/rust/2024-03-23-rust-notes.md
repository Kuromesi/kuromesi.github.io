---
title: Rust 学习笔记
date: 2024-03-23 22:38:06 +0800
categories: [Lang, Rust]
tags: [Rust]
author: kuromesi
---

## 变量

通过加 `mut` 使不可变变量可变，可以重新赋值。既然不可变变量是不可变的，那不就是常量吗？为什么叫变量？

变量和常量还是有区别的。在 Rust 中，以下程序是合法的：

```Rust
let a = 123;   // 可以编译，但可能有警告，因为该变量没有被使用
let a = 456;
```

但是如果 a 是常量就不合法：

```Rust
const a: i32 = 123;
let a = 456;
```

变量的值可以"重新绑定"，但在"重新绑定"以前不能私自被改变，这样可以确保在每一次"绑定"之后的区域里编译器可以充分的推理程序逻辑。

> [https://www.runoob.com/rust/rust-basic-syntax.html](https://www.runoob.com/rust/rust-basic-syntax.html)

## match 和 if let

[https://course.rs/basic/match-pattern/match-if-let.html#matches%E5%AE%8F](https://course.rs/basic/match-pattern/match-if-let.html#matches%E5%AE%8F)

## 生命周期

### 题外话

首先，需要指出的是，代码段中存在一些问题和误解。让我们逐一解析。

1. **返回局部变量的地址**:
   代码尝试从函数`foo`返回局部变量`a`的地址。这是危险的行为，因为局部变量在函数返回后，其占用的栈空间可能会被重用，这使得返回的地址指向的区域不再有效，对该地址的任何操作都是未定义的行为（undefined behavior）。虽然这里主要讨论`"xyz"`字符串的生命周期，但这个问题不应被忽视。

2. **字符串字面量的存储**:
   字符串字面量（如`"xyz"`）在C和C++中通常存储在程序的只读数据段，其生命周期与程序的整个运行时间相同。因此，即便是在它被定义的那个作用域结束后，该字符串仍然存在。所指向的`"xyz"`字符串在函数结束时不会被回收，因为它不是存在栈上的局部变量，而是存在全局的只读数据区。

3. **变量`c`的误解**:
   在这个函数中，指针`c`指向字符串字面量`"xyz"`。`c`本身是一个局部变量，存储在栈上，其作用域限于`foo`函数内部。但是它指向的内容（`"xyz"`）存放在整个程序生命周期都存在的只读内存段中。虽然`c`在函数结束时被销毁，但`c`指向的字符串`"xyz"`直至程序结束才会被“回收”——也就是说，其生命周期是整个程序运行期间。

因此，`"xyz"`直到程序运行完成才被回收，并不是因为它直接与`c`的作用域有关，而是因为字符串字面量的存储方式决定了其生命周期。而变量`a`的指针在函数返回后应该被认为是悬垂指针，不应该被使用。

最后，需要注意的是，在实践中返回局部变量的地址和依赖于字符串字面量在全局生命周期内存在的特性都不是好的编程习惯。返回局部变量的地址是危险的，应当避免；而正确地管理内存和理解变量的作用域对于写出安全、可维护的代码至关重要。

```c
int* foo() {
    int a;          // 变量a的作用域开始
    a = 100;
    char *c = "xyz";   // 变量c的作用域开始
    return &a;
}                   // 变量a和c的作用域结束
```

> [https://learnku.com/articles/44644](https://learnku.com/articles/44644)
>
> [https://www.runoob.com/rust/rust-lifetime.html](https://www.runoob.com/rust/rust-lifetime.html)

## 模块管理

rust 使用 mod 关键词用来定义模块和引入模块。use 仅仅是在存在模块的前提下，调整调用路径，而没有引入模块的功能，引入模块使用 mod。

`main.rs` 和 `lib.rs` 是包的根路径，两个具有不同的根，可以在其中通过定义 mod 来导入不同的包。

> [https://zyy.rs/post/rust-package-management/](https://zyy.rs/post/rust-package-management/#module-%E7%9A%84%E5%87%A0%E7%A7%8D%E5%B8%B8%E8%A7%81%E7%9A%84%E7%BB%84%E7%BB%87%E5%BD%A2%E5%BC%8F)
>
> [https://juejin.cn/post/7070765929117777957](https://juejin.cn/post/7070765929117777957)

## 静态分发和动态分发

![静态分发与动态分发](images/v2-b771fe4cfc6ebd63d9aff42840eb8e67.jpg)

回忆一下泛型章节我们提到过的，泛型是在编译期完成处理的：编译器会为**每一个泛型参数对应的具体类型生成一份代码**，这种方式是静态分发 (static dispatch) ，因为是在编译期完成的，对于运行期性能完全没有任何影响。

与静态分发相对应的是动态分发 (dynamic dispatch)，在这种情况下，直到运行时，才能确定需要调用什么方法。之前代码中的关键字 dyn 正是在强调这一“动态”的特点。

当使用特征对象时，Rust 必须使用动态分发。编译器无法知晓所有可能用于特征对象代码的类型，所以它也不知道应该调用哪个类型的哪个方法实现。为此，Rust 在运行时使用特征对象中的指针来知晓需要调用哪个方法。动态分发也阻止编译器有选择的内联方法代码，这会相应的禁用一些优化。

静态分发性能更好，但是可能会造成二进制文件膨胀，动态分发会带来运行时开销(寻址过程)。

> [https://zhuanlan.zhihu.com/p/163650432](https://zhuanlan.zhihu.com/p/163650432)
> 
> [https://course.rs/basic/trait/trait-object.html](https://course.rs/basic/trait/trait-object.html)

## async/wait 异步编程

> [https://course.rs/advance/async/getting-started.html](https://course.rs/advance/async/getting-started.html)

## 闭包

在阅读 Rust 圣经时，看到了这样一句话“这里取得的是s的不可变引用，所以是能Copy的。而如果拿到的是s的所有权或可变引用，都是不能Copy的。我们刚刚的代码就属于第二类，取得的是s的可变引用，没有实现Copy”，对此产生了疑问，于是 GPT 了一下。

这句话的意思是，在 Rust 中，当你获取一个变量的不可变引用时，如果该变量实现了 `Copy` trait，那么它的不可变引用也会表现出 `Copy` 的特性。这是因为不可变引用的语义是“共享访问”，不会对数据进行修改，所以可以安全地进行复制。但如果你获取的是该变量的所有权或可变引用，那么它们不会表现出 `Copy` 的特性。

1. 当你获取一个变量的不可变引用时，比如 `&T`：
   - 如果 `T` 类型实现了 `Copy` trait，那么获取到的不可变引用 `&T` 也会表现出 `Copy` 的特性，可以安全地进行复制。
   - 如果 `T` 类型没有实现 `Copy` trait，那么获取到的不可变引用 `&T` 就不会表现出 `Copy` 的特性，无法安全地进行复制。

2. 当你获取一个变量的可变引用时，比如 `&mut T`：
   - 无论 `T` 类型是否实现了 `Copy` trait，获取到的可变引用 `&mut T` 都不会表现出 `Copy` 的特性，因为可变引用可以用来修改数据，为了避免数据的不一致性，不会自动进行复制。

所以，根据获取的引用类型的不同，变量的 `Copy` 特性表现也会不同。

> [https://course.rs/advance/functional-programing/closure.html](https://course.rs/advance/functional-programing/closure.html)

## Issues

### VSCode Debug 只显示变量地址

rust analyzer debug engine settings 选择 lldb 作为引擎。