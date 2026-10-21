<script setup lang="ts">
// 能力卡片组：数据来自 ../data/features.ts（单一真相源，首页与介绍页共用）。
// 样式走 scoped —— .vp-doc 的 h3/p 规则特异性高于类选择器，组件内必须自带一份。
import { features } from '../data/features'
import PbIcon from './PbIcon.vue'
</script>

<template>
  <div class="pb-features">
    <article v-for="f in features" :key="f.title" class="pb-feature">
      <span class="pb-feature-icon">
        <PbIcon :name="f.icon" :size="24" />
      </span>
      <h3 class="pb-feature-title">{{ f.title }}</h3>
      <p class="pb-feature-desc">{{ f.details }}</p>
    </article>
  </div>
</template>

<style scoped>
.pb-features {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 16px;
  margin: 8px 0 0;
}

.pb-feature {
  padding: 22px 24px 24px;
  border: 1px solid var(--vp-c-divider);
  border-radius: 14px;
  background: var(--vp-c-bg-soft);
  transition: border-color 0.2s ease, transform 0.2s ease;
}

.pb-feature:hover {
  border-color: var(--vp-c-brand-1);
  transform: translateY(-2px);
}

.pb-feature-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 40px;
  height: 40px;
  margin-bottom: 14px;
  border-radius: 10px;
  background: var(--vp-c-brand-soft);
}

.pb-feature-title {
  margin: 0 0 6px;
  font-size: 16px;
  font-weight: 600;
  line-height: 24px;
  letter-spacing: -0.01em;
  color: var(--vp-c-text-1);
}

.pb-feature-desc {
  margin: 0;
  font-size: 14px;
  line-height: 22px;
  color: var(--vp-c-text-2);
}

@media (max-width: 960px) {
  .pb-features {
    grid-template-columns: repeat(2, 1fr);
  }
}

@media (max-width: 640px) {
  .pb-features {
    grid-template-columns: 1fr;
  }
}
</style>
