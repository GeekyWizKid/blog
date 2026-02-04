import { z, defineCollection } from 'astro:content';

const articleCollection = defineCollection({
  type: 'content',
  schema: z.object({
    title: z.string(),
    description: z.string().optional(),
    date: z.date(),
    updated: z.date().optional(),
    draft: z.boolean().default(false),
    tags: z.array(z.string()).default([]),
    categories: z.array(z.string()).default([]),
    image: z.string().optional(),
    featured: z.boolean().default(false),
  }),
});

export const collections = {
  tech: articleCollection,
  life: articleCollection,
  books: articleCollection,
};
