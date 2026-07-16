"""Build transparent, evenly aligned UI atlases from the supplied source sheets.

The source art is preserved pixel-for-pixel. Background removal uses the closed
dark outline around each illustration as a flood-fill barrier; no generative
image processing or resampling is involved.
"""

from __future__ import annotations

from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
UI_DIR = ROOT / "assets" / "ui"

INGREDIENT_REGIONS = [
    (41, 101, 240, 240),
    (288, 115, 225, 225),
    (522, 111, 230, 230),
    (766, 110, 230, 230),
    (972, 114, 240, 240),
    (35, 369, 235, 235),
    (291, 382, 220, 220),
    (515, 375, 230, 230),
    (750, 378, 230, 230),
    (986, 377, 235, 235),
    (34, 630, 235, 235),
    (277, 639, 225, 225),
    (509, 641, 225, 225),
    (750, 643, 230, 230),
    (996, 640, 225, 225),
    (26, 890, 250, 250),
    (263, 891, 250, 250),
    (510, 903, 235, 235),
    (742, 903, 235, 235),
    (977, 903, 235, 235),
]

RECIPE_REGIONS = [
    (83, 68, 340, 279),
    (460, 68, 339, 279),
    (834, 68, 338, 279),
    (96, 334, 305, 305),
    (475, 334, 305, 292),
    (848, 333, 305, 305),
    (67, 641, 370, 270),
    (457, 625, 340, 280),
    (834, 632, 338, 261),
    (69, 910, 375, 285),
    (515, 910, 225, 280),
    (850, 880, 320, 345),
]

NAVIGATION_REGIONS = [
    (15, 255, 315, 345),
    (330, 250, 300, 350),
    (620, 270, 310, 330),
    (925, 260, 315, 350),
    (10, 665, 330, 330),
    (330, 645, 310, 360),
    (620, 665, 310, 335),
    (930, 675, 310, 315),
]

# Both supplied status-bubble sheets use the same six-column layout.  The
# first six rows are complete and contain every runtime state currently used
# by customers and staff.  Explicit edges keep the generous source padding
# while avoiding pixels from neighbouring bubbles.
STATUS_BUBBLE_X_EDGES = [0, 219, 419, 618, 819, 1013, 1254]
STATUS_BUBBLE_Y_EDGES = [0, 206, 381, 563, 743, 922, 1079]
STATUS_BUBBLE_REGIONS = [
    (
        STATUS_BUBBLE_X_EDGES[column],
        STATUS_BUBBLE_Y_EDGES[row],
        STATUS_BUBBLE_X_EDGES[column + 1] - STATUS_BUBBLE_X_EDGES[column],
        STATUS_BUBBLE_Y_EDGES[row + 1] - STATUS_BUBBLE_Y_EDGES[row],
    )
    for row in range(6)
    for column in range(6)
]


def flood_exterior(passable: np.ndarray) -> np.ndarray:
    """Return background pixels reachable from a crop border."""
    height, width = passable.shape
    exterior = np.zeros((height, width), dtype=bool)
    queue: deque[tuple[int, int]] = deque()

    def seed(y: int, x: int) -> None:
        if passable[y, x] and not exterior[y, x]:
            exterior[y, x] = True
            queue.append((y, x))

    for x in range(width):
        seed(0, x)
        seed(height - 1, x)
    for y in range(height):
        seed(y, 0)
        seed(y, width - 1)

    while queue:
        y, x = queue.popleft()
        if y > 0:
            seed(y - 1, x)
        if y + 1 < height:
            seed(y + 1, x)
        if x > 0:
            seed(y, x - 1)
        if x + 1 < width:
            seed(y, x + 1)
    return exterior


def largest_component(mask: np.ndarray) -> np.ndarray:
    """Discard any isolated dark background flecks outside the illustration."""
    height, width = mask.shape
    visited = np.zeros_like(mask)
    largest: list[tuple[int, int]] = []
    for start_y, start_x in zip(*np.where(mask & ~visited)):
        if visited[start_y, start_x]:
            continue
        component: list[tuple[int, int]] = []
        queue: deque[tuple[int, int]] = deque([(int(start_y), int(start_x))])
        visited[start_y, start_x] = True
        while queue:
            y, x = queue.popleft()
            component.append((y, x))
            for next_y, next_x in (
                (y - 1, x),
                (y + 1, x),
                (y, x - 1),
                (y, x + 1),
                (y - 1, x - 1),
                (y - 1, x + 1),
                (y + 1, x - 1),
                (y + 1, x + 1),
            ):
                if 0 <= next_y < height and 0 <= next_x < width:
                    if mask[next_y, next_x] and not visited[next_y, next_x]:
                        visited[next_y, next_x] = True
                        queue.append((next_y, next_x))
        if len(component) > len(largest):
            largest = component

    result = np.zeros_like(mask)
    for y, x in largest:
        result[y, x] = True
    return result


def remove_background_holes(crop: np.ndarray, mask: np.ndarray, exterior: np.ndarray) -> np.ndarray:
    """Clear enclosed regions whose color still matches the source background."""
    background_color = np.median(crop[exterior], axis=0)
    luminance = crop.mean(axis=2)
    candidates = mask & (luminance >= 60.0)
    height, width = candidates.shape
    visited = np.zeros_like(candidates)
    for start_y, start_x in zip(*np.where(candidates & ~visited)):
        if visited[start_y, start_x]:
            continue
        component: list[tuple[int, int]] = []
        queue: deque[tuple[int, int]] = deque([(int(start_y), int(start_x))])
        visited[start_y, start_x] = True
        while queue:
            y, x = queue.popleft()
            component.append((y, x))
            for next_y, next_x in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= next_y < height and 0 <= next_x < width:
                    if candidates[next_y, next_x] and not visited[next_y, next_x]:
                        visited[next_y, next_x] = True
                        queue.append((next_y, next_x))
        if len(component) < 32:
            continue
        component_colors = np.asarray([crop[y, x] for y, x in component])
        median_color = np.median(component_colors, axis=0)
        color_distance = float(np.linalg.norm(median_color - background_color))
        chroma = float(median_color.max() - median_color.min())
        if color_distance < 24.0 and chroma < 24.0:
            for y, x in component:
                mask[y, x] = False
    return mask


def extract_subject(
    source: Image.Image,
    region: tuple[int, int, int, int],
    top_center_filter: tuple[int, int, int] | None = None,
    discard_top_rows: int = 0,
    clear_background_holes: bool = False,
) -> Image.Image:
    x, y, width, height = region
    crop = np.asarray(source.crop((x, y, x + width, y + height)).convert("RGB"))
    luminance = crop.mean(axis=2)
    # The supplied background stays above ~67/255; the closed outlines remain
    # below 60 and form a reliable barrier even on brown food illustrations.
    exterior = flood_exterior(luminance >= 60.0)
    subject_mask = ~exterior
    if discard_top_rows > 0:
        subject_mask[:discard_top_rows, :] = False
    if top_center_filter is not None:
        rows, left, right = top_center_filter
        subject_mask[:rows, :left] = False
        subject_mask[:rows, right:] = False
    subject_mask = largest_component(subject_mask)
    if clear_background_holes:
        subject_mask = remove_background_holes(crop, subject_mask, exterior)
    subject_y, subject_x = np.where(subject_mask)
    if subject_x.size == 0:
        raise RuntimeError(f"No subject found in region {region}")

    left = int(subject_x.min())
    top = int(subject_y.min())
    right = int(subject_x.max()) + 1
    bottom = int(subject_y.max()) + 1
    rgba = np.dstack((crop, subject_mask.astype(np.uint8) * 255))
    return Image.fromarray(rgba, "RGBA").crop((left, top, right, bottom))


def build_atlas(
    source_name: str,
    output_name: str,
    regions: list[tuple[int, int, int, int]],
    columns: int,
    rows: int,
    cell_size: tuple[int, int],
    top_center_filters: dict[int, tuple[int, int, int]] | None = None,
    discard_top_rows: dict[int, int] | None = None,
    clear_holes_indices: set[int] | None = None,
) -> None:
    source = Image.open(UI_DIR / source_name).convert("RGB")
    cell_width, cell_height = cell_size
    atlas = Image.new("RGBA", (columns * cell_width, rows * cell_height), (0, 0, 0, 0))
    for index, region in enumerate(regions):
        subject = extract_subject(
            source,
            region,
            top_center_filter=(top_center_filters or {}).get(index),
            discard_top_rows=(discard_top_rows or {}).get(index, 0),
            clear_background_holes=index in (clear_holes_indices or set()),
        )
        if subject.width > cell_width or subject.height > cell_height:
            raise RuntimeError(
                f"Subject {index} ({subject.size}) exceeds cell {cell_size}"
            )
        cell_x = (index % columns) * cell_width
        cell_y = (index // columns) * cell_height
        paste_x = cell_x + (cell_width - subject.width) // 2
        paste_y = cell_y + (cell_height - subject.height) // 2
        atlas.alpha_composite(subject, (paste_x, paste_y))
    output = UI_DIR / output_name
    atlas.save(output, optimize=True)
    print(f"WROTE {output} {atlas.size} mode={atlas.mode}")


def build_lock() -> None:
    source_path = UI_DIR / "lock_icon_source.png"
    source = Image.open(source_path).convert("RGB")
    subject = extract_subject(
        source,
        (0, 0, source.width, source.height),
        clear_background_holes=True,
    )
    padding = 24
    output_image = Image.new(
        "RGBA",
        (subject.width + padding * 2, subject.height + padding * 2),
        (0, 0, 0, 0),
    )
    output_image.alpha_composite(subject, (padding, padding))
    output = UI_DIR / "lock_icon.png"
    output_image.save(output, optimize=True)
    print(f"WROTE {output} {output_image.size} mode={output_image.mode}")


def main() -> None:
    build_atlas(
        "ingredient_icons.png",
        "ingredient_icons_transparent.png",
        INGREDIENT_REGIONS,
        columns=5,
        rows=4,
        cell_size=(240, 240),
    )
    build_atlas(
        "recipe_icons.png",
        "recipe_icons_transparent.png",
        RECIPE_REGIONS,
        columns=3,
        rows=4,
        cell_size=(352, 328),
        discard_top_rows={11: 17},
    )
    build_atlas(
        "navigation_icons_source.png",
        "navigation_icons.png",
        NAVIGATION_REGIONS,
        columns=4,
        rows=2,
        cell_size=(328, 336),
        clear_holes_indices={7},
    )
    build_atlas(
        "status_bubbles/customer_bubbles_source.png",
        "status_bubbles/customer_bubbles.png",
        STATUS_BUBBLE_REGIONS,
        columns=6,
        rows=6,
        cell_size=(192, 192),
    )
    build_atlas(
        "status_bubbles/staff_bubbles_source.png",
        "status_bubbles/staff_bubbles.png",
        STATUS_BUBBLE_REGIONS,
        columns=6,
        rows=6,
        cell_size=(192, 192),
    )
    build_lock()


if __name__ == "__main__":
    main()
