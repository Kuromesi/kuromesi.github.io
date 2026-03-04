# Kuromesi Blog

[![Hugo](https://img.shields.io/badge/Hugo-FF4088?style=flat&logo=hugo)](https://gohugo.io/)
[![Blowfish Theme](https://img.shields.io/badge/Theme-Blowfish-5636D3?style=flat)](https://blowfish.page/)

> **Cloud Native Explorer | Kubernetes & Istio Enthusiast**

A personal blog built with [Hugo](https://gohugo.io/) and the [Blowfish](https://blowfish.page/) theme, focusing on cloud-native technologies, Kubernetes, Istio, and related topics.

## 🌐 Live Site

Visit the blog at: [https://kuromesi.github.io/](https://kuromesi.github.io/)

## 🚀 Quick Start

### Prerequisites

- [Hugo](https://gohugo.io/installation/) (Extended version recommended)
- Git

### Local Development

```bash
# Clone the repository
git clone https://github.com/kuromesi/kuromesi.github.io.git
cd kuromesi.github.io

# Start Hugo development server
hugo server -D
```

The site will be available at `http://localhost:1313/`

### Build for Production

```bash
# Build static files
hugo --minify
```

Production files will be generated in the `public/` directory.

## 📁 Project Structure

```
kuromesi.github.io/
├── config/_default/     # Hugo & theme configuration
├── content/             # Blog posts and pages
│   ├── _index.md        # Homepage content
│   └── posts/           # Blog articles
├── themes/blowfish/     # Blowfish theme
├── static/              # Static assets
├── assets/              # Processed assets (images, etc.)
├── layouts/             # Custom layouts
└── data/                # Site data files
```

## ⚙️ Configuration

Key configuration files:

- `config/_default/hugo.toml` - Site settings (baseURL, language, etc.)
- `config/_default/params.toml` - Theme customization options
- `config/_default/languages.zh-cn.toml` - Language-specific settings

### Theme Features

- 🎨 **Color Scheme**: Princess theme with auto-switching light/dark mode
- 📱 **Responsive Design**: Mobile-friendly layout
- 🔍 **Search**: Built-in search functionality
- 📊 **Analytics**: Support for multiple analytics providers
- 📝 **Markdown**: Enhanced markdown support with emoji
- 🔗 **Social Sharing**: Article sharing capabilities

## ✍️ Creating New Content

### New Blog Post

```bash
hugo new content posts/my-new-post.md
```

Front matter template:

```markdown
---
title: "Your Post Title"
description: "Brief description"
date: 2026-03-04
tags: ["kubernetes", "cloud-native"]
categories: ["DevOps"]
draft: false
---

Your content here...
```

## 🛠️ Technologies

- **[Hugo](https://gohugo.io/)** - Static site generator
- **[Blowfish](https://blowfish.page/)** - Hugo theme
- **[Tailwind CSS](https://tailwindcss.com/)** - CSS framework (via theme)
- **[Fuse.js](https://fusejs.io/)** - Search functionality (via theme)

## 📄 License

This project is open source and available under the [MIT License](LICENSE).

## 🤝 Contributing

Feel free to open issues or submit pull requests for any suggestions or improvements.

## 📞 Contact

- **Blog**: [https://kuromesi.github.io/](https://kuromesi.github.io/)
- **GitHub**: [@kuromesi](https://github.com/kuromesi)

---

Built with ❤️ using Hugo & Blowfish
