import rss from '@astrojs/rss';
import { getCollection } from 'astro:content';
import type { APIContext } from 'astro';

export async function GET(context: APIContext) {
  const [tech, games, books, life] = await Promise.all([
    getCollection('tech', ({ data }) => !data.draft),
    getCollection('games', ({ data }) => !data.draft),
    getCollection('books', ({ data }) => !data.draft),
    getCollection('life', ({ data }) => !data.draft),
  ]);

  const allPosts = [
    ...tech.map(post => ({ ...post, category: 'tech' })),
    ...games.map(post => ({ ...post, category: 'games' })),
    ...books.map(post => ({ ...post, category: 'books' })),
    ...life.map(post => ({ ...post, category: 'life' })),
  ].sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf());

  return rss({
    title: '劝退师说',
    description: 'AI Agents · LLM 工具链 · 分布式',
    site: context.site!,
    items: allPosts.map(post => ({
      title: post.data.title,
      description: post.data.description,
      pubDate: post.data.date,
      link: `/${post.category}/${post.slug}/`,
    })),
  });
}
