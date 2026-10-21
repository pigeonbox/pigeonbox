<script setup lang="ts">
// 文档门户的搜索入口：复用 VitePress 内置 local search（顶栏那枚），
// 但放到首页 hero 下方做成大块入口——顶栏搜索在窄屏会藏进汉堡菜单，
// 门户页的第一动作应该是"搜"。
// 窄屏隐藏（.VPNavBarSearch 在 <960px 不渲染，点了没反应）。
const openSearch = () => {
  const btn = document.querySelector<HTMLButtonElement>('.VPNavBarSearch .DocSearch-Button')
  if (btn) btn.click()
}
</script>

<template>
  <button class="pb-search-cta" type="button" @click="openSearch">
    <svg class="pb-search-cta-icon" width="18" height="18" viewBox="0 0 24 24" fill="none"
      stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <circle cx="11" cy="11" r="7" />
      <path d="m20 20-3.5-3.5" />
    </svg>
    <span class="pb-search-cta-text">搜索文档</span>
    <kbd class="pb-search-cta-kbd">⌘ K</kbd>
  </button>
</template>

<style scoped>
.pb-search-cta {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  max-width: 520px;
  /* 左对齐：与 hero 标题、入口卡同一左基线（居中会与左对齐文案错位） */
  margin: 8px 0 0;
  padding: 12px 16px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 12px;
  background: var(--vp-c-bg-soft);
  color: var(--vp-c-text-2);
  font-size: 14px;
  text-align: left;
  cursor: pointer;
  transition: border-color 0.2s ease, color 0.2s ease;
}

.pb-search-cta:hover {
  border-color: var(--vp-c-brand-1);
  color: var(--vp-c-text-1);
}

.pb-search-cta-icon {
  flex-shrink: 0;
  color: var(--vp-c-brand-1);
}

.pb-search-cta-text {
  flex: 1;
}

.pb-search-cta-kbd {
  flex-shrink: 0;
  padding: 2px 6px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 5px;
  background: var(--vp-c-bg);
  font-family: var(--vp-font-family-mono);
  font-size: 11px;
  line-height: 16px;
  color: var(--vp-c-text-3);
}

@media (max-width: 960px) {
  /* 顶栏搜索在窄屏收进汉堡菜单，这里点了没反应，直接隐藏 */
  .pb-search-cta {
    display: none;
  }
}
</style>
