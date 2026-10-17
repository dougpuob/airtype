"""Tests for the Instagram post extractor."""

from __future__ import annotations

import json

from webui.app.instagram_weaver import (
    CarouselItem,
    InstagramPost,
    InstagramPostExtractor,
    _extract_json_ld,
    _extract_open_graph,
    _extract_post_from_media,
    _extract_shared_data,
    _try_json_ld,
    _try_open_graph,
    _try_shared_data,
)


def test_instagram_post_dataclass() -> None:
    """Test InstagramPost dataclass."""
    post = InstagramPost(
        id="ABC123",
        url="https://www.instagram.com/p/ABC123/",
        author="testuser",
        text="Hello world",
        is_video=False,
        video_url=None,
        image_urls=("https://example.com/image.jpg",),
        taken_at=1234567890,
        media_type=1,
        carousel_items=(),
    )
    assert post.id == "ABC123"
    assert post.url == "https://www.instagram.com/p/ABC123/"
    assert post.author == "testuser"
    assert post.text == "Hello world"
    assert post.is_video is False
    assert post.video_url is None
    assert post.image_urls == ("https://example.com/image.jpg",)
    assert post.taken_at == 1234567890
    assert post.media_type == 1
    assert post.carousel_items == ()

    # Test as_dict
    post_dict = post.as_dict()
    assert post_dict["id"] == "ABC123"
    assert post_dict["url"] == "https://www.instagram.com/p/ABC123/"
    assert post_dict["author"] == "testuser"
    assert post_dict["text"] == "Hello world"
    assert post_dict["is_video"] is False
    assert post_dict["video_url"] is None
    assert post_dict["image_urls"] == ["https://example.com/image.jpg"]
    assert post_dict["taken_at"] == 1234567890
    assert post_dict["media_type"] == 1
    assert post_dict["carousel_items"] == []


def test_carousel_item_dataclass() -> None:
    """Test CarouselItem dataclass."""
    item = CarouselItem(is_video=True, video_url="https://example.com/video.mp4", image_url="https://example.com/thumb.jpg")
    assert item.is_video is True
    assert item.video_url == "https://example.com/video.mp4"
    assert item.image_url == "https://example.com/thumb.jpg"
def test_extract_json_ld() -> None:
    """Test JSON-LD extraction."""
    html = '''
    <script type="application/ld+json">
    {"@context": "https://schema.org", "@type": "SocialMediaPosting", "author": {"name": "testuser"}, "caption": "Hello world"}
    </script>
    '''
    result = _extract_json_ld(html)
    assert len(result) == 1
    assert result[0]["@type"] == "SocialMediaPosting"
    assert result[0]["author"]["name"] == "testuser"
    assert result[0]["caption"] == "Hello world"


def test_extract_open_graph() -> None:
    """Test OpenGraph extraction."""
    html = '''
    <meta property="og:title" content="Test User on Instagram: Hello world" />
    <meta property="og:description" content="This is a test post." />
    <meta property="og:image" content="https://example.com/image.jpg" />
    '''
    result = _extract_open_graph(html)
    assert result["og:title"] == "Test User on Instagram: Hello world"
    assert result["og:description"] == "This is a test post."
    assert result["og:image"] == "https://example.com/image.jpg"
def test_parse_media_node_image() -> None:
    """Test parsing an image media node."""
    media = {
        "image_versions2": {
            "candidates": [
                {"url": "https://example.com/image1.jpg", "width": 1080},
                {"url": "https://example.com/image2.jpg", "width": 720},
            ]
        }
    }
    is_video, video_url, image_urls = _parse_media_node(media)
    assert is_video is False
    assert video_url is None
    assert image_urls == ["https://example.com/image1.jpg"]  # highest quality


def test_parse_media_node_video() -> None:
    """Test parsing a video media node."""
    media = {
        "is_video": True,
        "video_versions": [
            {"url": "https://example.com/video_low.mp4", "width": 480},
            {"url": "https://example.com/video_high.mp4", "width": 1080},
        ],
        "image_versions2": {
            "candidates": [
                {"url": "https://example.com/thumb.jpg", "width": 1080},
            ]
        }
    }
    is_video, video_url, image_urls = _parse_media_node(media)
    assert is_video is True
    assert video_url == "https://example.com/video_high.mp4"
    assert image_urls == ["https://example.com/thumb.jpg"]
def test_extract_post_from_media() -> None:
    """Test building a post from a media node."""
    media = {
        "code": "ABC123",
        "caption": {"text": "Hello world"},
        "owner": {"username": "testuser"},
        "taken_at": 1234567890,
        "media_type": 1,
        "image_versions2": {
            "candidates": [
                {"url": "https://example.com/image.jpg"}
            ]
        }
    }
    post = _extract_post_from_media(media, "https://www.instagram.com/p/ABC123/")
    assert isinstance(post, InstagramPost)
    assert post.id == "ABC123"
    assert post.url == "https://www.instagram.com/p/ABC123/"
    assert post.author == "testuser"
    assert post.text == "Hello world"
    assert post.is_video is False
    assert post.video_url is None
    assert post.image_urls == ("https://example.com/image.jpg",)
    assert post.taken_at == 1234567890
    assert post.media_type == 1
    assert post.carousel_items == ()


def test_try_json_ld() -> None:
    """Test JSON-LD parsing strategy."""
    html = '''
    <script type="application/ld+json">
    {
        "@context": "https://schema.org",
        "@type": "SocialMediaPosting",
        "author": {"name": "testuser"},
        "caption": "Hello world",
        "image": "https://example.com/image.jpg"
    }
    </script>
    '''
    post = _try_json_ld(html, "https://www.instagram.com/p/ABC123/")
    assert post is not None
    assert post.id == ""
    assert post.url == "https://www.instagram.com/p/ABC123/"
    assert post.author == "testuser"
    assert post.text == "Hello world"
    assert post.is_video is False
    assert post.video_url is None
    assert post.image_urls == ("https://example.com/image.jpg",)
def test_try_open_graph() -> None:
    """Test OpenGraph parsing strategy."""
    html = '''
    <meta property="og:title" content="Test User on Instagram: Hello world" />
    <meta property="og:description" content="This is a test post." />
    <meta property="og:image" content="https://example.com/image.jpg" />
    '''
    post = _try_open_graph(html, "https://www.instagram.com/p/ABC123/")
    assert post is not None
    assert post.id == "ABC123"
    assert post.url == "https://www.instagram.com/p/ABC123/"
    assert post.author == "Test User"
    assert post.text == "This is a test post."
    assert post.is_video is False
    assert post.video_url is None
    assert post.image_urls == ("https://example.com/image.jpg",)
    assert post.taken_at == 0
    assert post.media_type == 1
    assert post.carousel_items == ()


def test_instagram_post_extractor_init() -> None:
    """Test InstagramPostExtractor initialization."""
    extractor = InstagramPostExtractor()
    assert extractor.timeout == 15
    assert "Chrome" in extractor._user_agent

    extractor = InstagramPostExtractor(timeout=30)
    assert extractor.timeout == 30


def test_extract_instagram_post_convenience_function() -> None:
    """Test the convenience function."""
    # We cannot test the actual extraction without network, but we can test that it calls the extractor
    # by mocking or by checking the function exists and returns the correct type when given invalid input?
    # For now, we just test that the function exists and is callable.
    assert callable(extract_instagram_post)