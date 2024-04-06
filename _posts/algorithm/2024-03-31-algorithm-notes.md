---
title: 算法刷题笔记
date: 2024-03-31 10:49:06 +0800
categories: [Algorithm, Notes]
tags: [algorithm]
author: kuromesi
math: true
---

## [2952. 需要添加的硬币的最小数量](https://leetcode.cn/problems/minimum-number-of-coins-to-be-added/description/?envType=daily-question&envId=2024-03-25)

### 题目

给你一个下标从 0 开始的整数数组 coins，表示可用的硬币的面值，以及一个整数 target 。

如果存在某个 coins 的子序列总和为 x，那么整数 x 就是一个 **可取得的金额** 。

返回需要添加到数组中的 **任意面值** 硬币的 最小数量 ，使范围 [1, target] 内的每个整数都属于 可取得的金额 。

数组的 **子序列** 是通过删除原始数组的一些（可能不删除）元素而形成的新的 **非空** 数组，删除过程不会改变剩余元素的相对位置。

### 解题思路

对于一个数 $x$，如果 $[1, x - 1]$ 可以取得，那么对于 $y \leq x$来说，一定有 $[1, y - 1]$ 可以取得，因此遍历到新的面额 $y$，一定有 $[1, x + y - 1]$ 可以取得。而如果 $y \gt x$ 时，加上新的面额无法保证 $[1, x + y - 1]$ 可以取得。因为 $[x, y - 1]$ 是无法取得的。

例如 $x = 4$，$y = 5$，此时存在的面额为 $[1, 2]$，如果添加面额 $4$，则新的取值范围变为 $[1, 7]$，但很明显 $4$ 是无法取到的。

因此此时只能在原有 $x$ 的基础上再加一个 $x$，此时新的可取的面额为 $[1, 2x - 1]$。而由于 $x$ 不存在与原有的硬币序列中，因此需要对 答案加一。

持续上述过程，直到覆盖 target。

### 题解

```java
class Solution {
    public int minimumAddedCoins(int[] coins, int target) {
        Arrays.sort(coins);
        int idx = 0, x = 1, ans = 0;
        while (x <= target) {
            if (idx < coins.length && coins[idx] <= x) {
                x += coins[idx];
                idx++;
            } else {
                x *= 2;
                ans++;
            }
        }
        return ans;
    }
}
```

## 淘天 20240403 题 1

### 题目

给你一个数组，有 q 次查询，每次查询查区间 [l，r]，从 l 到 r 拼接的数是否能被 3 整除（例如 [11，45，14]，对于区间 [1，3] 拼接 → 114514，不可被整除，输出 NO 否则 YES ）

### 解题思路

本题最重要的是需要推导出如下形式的式子：

$$(x + y + z) \% 3 = (10^ax + 10^by + z) \% 3$$

之后便可以简单地利用前缀和进行求解。根据：

$$
(a + b) \% c = (a \% c + b \% c) \% c
$$

可以得到：

$$
(10^ax + 10^by + z) \% 3 = (10^ax \% 3 + 10^by \% 3 + z \% 3) \% 3
$$

根据：

$$
(ax) \% c = (a \% c \times x \% c) \% c
$$

可以得到：

$$
((10^a \% 3 \times x \% c) \% c + (10^b \% 3 \times y \% c) \% c + z \% 3)
$$

因为：

$$
10^n \% 3 = 1
$$

因此原式可以化简为：

$$
\begin{aligned}
((x \% 3) \% 3 + (y \% 3) \% 3 + z \% 3) \% 3 &= (x \% 3 + y \% 3 + z \% 3) \% 3 \\

&= (x + y + z) \% 3
\end{aligned}
$$

> [取余运算法则](https://blog.csdn.net/Ash_Zheng/article/details/38541777)

### 题解

```python
def is_triple(arr_sum, l, r):
    return (arr_sum[r] - arr_sum[l - 1]) % 3 == 0

n, q = map(int, input().split())
arr = list(map(int, input().split()))

arr_sum = []
arr_sum.append(0)
for i in arr:
    arr_sum.append(arr_sum[-1] + i)

ans = []
for i in range(q):
    l, r = map(int, input().split())
    ans.append("YES" if is_triple(arr_sum, l, r) else "NO")

for a in ans:
    print(a)

# 3 1
# 11 45 14
# 1 3
# No
```

## 淘天 20240403 题 2