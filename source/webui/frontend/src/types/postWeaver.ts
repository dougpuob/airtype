export type WovenPost = {
  text: string;
  url?: string;
  mediaUrls?: string[];
};

export type PostImportResponse = {
  kind?: "post";
  url?: string;
  title?: string;
  text?: string;
  media_urls?: string[];
  markdown?: string;
  guid?: string;
  source_id?: string;
};

export type ThreadsChainResponse = {
  kind?: "post";
  author?: string;
  url?: string;
  guid?: string;
  source_id?: string;
  markdown?: string;
  posts?: Array<{
    text?: string;
    url?: string;
    media_urls?: string[];
  }>;
  warnings?: string[];
};
