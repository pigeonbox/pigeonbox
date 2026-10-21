<script setup lang="ts">
// 统一线性图标。形状定义见 ../icons.ts。
import { computed } from 'vue'
import { icons } from '../icons'

const props = withDefaults(defineProps<{ name: string; size?: number }>(), { size: 24 })

const shapes = computed(() => icons[props.name] ?? [])
</script>

<template>
  <svg
    class="pb-icon"
    :width="props.size"
    :height="props.size"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    stroke-width="1.75"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
  >
    <template v-for="(s, i) in shapes" :key="i">
      <path v-if="s.t === 'path'" :d="s.d" />
      <circle v-else-if="s.t === 'circle'" :cx="s.cx" :cy="s.cy" :r="s.r" />
      <rect v-else-if="s.t === 'rect'" :x="s.x" :y="s.y" :width="s.w" :height="s.h" :rx="s.rx" />
    </template>
  </svg>
</template>

<style scoped>
.pb-icon {
  display: block;
  color: var(--vp-c-brand-1);
}
</style>
