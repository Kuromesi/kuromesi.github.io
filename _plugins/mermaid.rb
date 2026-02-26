# Jekyll hook to inject Mermaid support into pages/posts
# Control via front matter: `mermaid: true` to enable, `mermaid: false` to disable
# If not set in front matter, falls back to site config `mermaid.enabled`
Jekyll::Hooks.register :site, :post_render do |site|
  # Helper to process a document
  process_doc = lambda do |doc|
    # Determine if mermaid should be enabled for this doc
    # Priority: 1) front matter setting, 2) site config, 3) auto-detect mermaid blocks
    if doc.data['mermaid'] == false
      # Explicitly disabled in front matter
      next
    elsif doc.data['mermaid'] == true
      # Explicitly enabled in front matter (overrides site config)
      mermaid_enabled = true
    elsif site.config['mermaid'] && site.config['mermaid']['enabled']
      # Site-wide enabled
      mermaid_enabled = true
    else
      # Check if page has mermaid code blocks (auto-enable)
      mermaid_enabled = doc.output.include?('language-mermaid')
    end

    if mermaid_enabled && doc.output.include?('language-mermaid')
      # Convert language-mermaid code blocks to mermaid divs
      doc.output = doc.output.gsub(/<pre><code class="language-mermaid">(.*?)<\/code><\/pre>/m, '<div class="mermaid">\1</div>')
      # Inject mermaid script before closing body tag
      unless doc.output.include?('mermaid.initialize')
        doc.output = doc.output.gsub('</body>', "<script type=\"module\">\n  import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';\n  mermaid.initialize({ startOnLoad: true, theme: 'default' });\n</script>\n</body>")
      end
    end
  end

  site.pages.each(&process_doc)
  site.posts.each(&process_doc)
end
