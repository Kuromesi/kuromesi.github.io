---
title: Ztunnel 基础
date: 2024-03-26 09:47:06 +0800
categories: [Cloud Native, Istio]
tags: [istio]
author: kuromesi
---

## 多域名 (SAN) SSL 证书

（1）单域名SSL：顾名思义，这类证书只保护一个域名，这些域名形如www.wosign.com；pay.domain.net；shop.store.cn等；如果您为www前缀的域名申请证书时，默认是可以保护不带www的主域名，但是当您为其他前缀的子域名申请证书时，则只能保护当前子域名，不能保护不带前缀的主域名。

（2）多域名SSL：这种类型的证书可以同时保护多个域名，例如：同时保护www.wosing.com、pay.domain.com、shop.store.com等，但是不同品牌的多域名证书默认保护的域名数量不一样。

（3）通配符SSL：通配符证书可以保护一个域名下的同级子域名，并且不限制该子域名的数量。例如：这类证书可以保护freessl.wosign.com，也可以保护bbs.wosign.com，也就是说他可以保护wosign.com这个域名下的所有同级子域名。

一张多域名SSL证书可以保护多个域名（Subject Alternative Name），因此又名SAN SSL，或UCC SSL证书。多域名证书支持添加多个不同的主域名或子域名，远比为每个域名单独申请SSL证书更省钱， 还能简化验证流程，方便证书管理及续费。同时，多域名证书也是邮件服务器（Exchange Server）加密推荐申请使用的证书。

```Rust
// src/proxy/outbound.rs
let mut allowed_sans: Vec<Identity> = Vec::new();
                for san in req.upstream_sans.iter() {
                    match Identity::from_str(san) {
                        Ok(ident) => allowed_sans.push(ident.clone()),
                        Err(err) => {
                            warn!("error parsing SAN {}: {}", san, err)
                        }
                    }
                }
```

> [https://zhuanlan.zhihu.com/p/39806386](https://zhuanlan.zhihu.com/p/39806386)
>
> [https://www.wosign.com/column/ssl_20211231.htm](https://www.wosign.com/column/ssl_20211231.htm)