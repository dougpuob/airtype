export type WovenPost = {
  text: string;
  url?: string;
  mediaUrls?: string[];
};

export type PostImportResponse = {
  url?: string;
  title?: string;
  text?: string;
  media_urls?: string[];
};

export type ThreadsChainResponse = {
  author?: string;
  posts?: Array<{
    text?: string;
    url?: string;
    media_urls?: string[];
  }>;
};
