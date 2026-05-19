/// Test corpus for semantic search quality evaluation.
///
/// 30 AI-image prompts (0-19 canonical, 20-29 hard distractors) and
/// 20 queries ranging from easy exact-vocab matches to hard inference
/// and taxonomic queries.  Imported by test_search_quality.zig.

pub const Query = struct {
    text: []const u8,
    relevant: []const usize,
};

pub const PROMPTS = [_][]const u8{
    // 0
    "A majestic dragon soaring above snow-capped mountains, " ++
        "scales gleaming in golden sunlight, wings spread wide, " ++
        "fire breathing, photorealistic, 8k, highly detailed",
    // 1
    "Portrait of an elegant elven warrior woman in ornate silver armor, " ++
        "flowing auburn hair, piercing green eyes, forest background, " ++
        "fantasy art, epic composition, dramatic lighting",
    // 2
    "Cyberpunk cityscape at night, neon signs reflecting on rain-slicked streets, " ++
        "flying cars, towering skyscrapers, blade runner aesthetic, " ++
        "cinematic lighting, foggy atmosphere, vibrant colors",
    // 3
    "Serene Japanese zen garden at sunrise, raked gravel patterns, " ++
        "cherry blossom trees in full bloom, stone lanterns, " ++
        "morning mist, watercolor style, peaceful",
    // 4
    "Cute tabby cat sitting on a windowsill in soft afternoon sunlight, " ++
        "warm cozy interior, shallow depth of field, bokeh background, " ++
        "whiskers catching the light, photography",
    // 5
    "Epic space battle between massive starships, laser beams, " ++
        "explosions, colorful nebula background, cinematic composition, " ++
        "science fiction, highly detailed, photorealistic",
    // 6
    "Ancient stone castle on a cliff overlooking the stormy sea, " ++
        "dramatic dark clouds, lightning strike, gothic atmosphere, " ++
        "oil painting style, moody, ominous",
    // 7
    "Hyperrealistic portrait of a wise old wizard with a long grey beard, " ++
        "wearing ornate purple robes covered in arcane symbols, " ++
        "holding a glowing crystal staff, mystical smoke swirling",
    // 8
    "Breathtaking sunset over the African savanna, acacia trees " ++
        "silhouetted against orange and purple sky, giraffes in the distance, " ++
        "golden hour light, wildlife photography",
    // 9
    "Mechanical steampunk butterfly with intricate clockwork wings, " ++
        "brass gears and copper pipes visible, flying over Victorian London " ++
        "rooftops, fog and coal smoke, warm sepia tones",
    // 10
    "Dark enchanted forest path in autumn, fallen leaves in deep crimson and gold, " ++
        "twisted ancient oak trees, mysterious glowing lights in the distance, " ++
        "atmospheric, moody, fantasy",
    // 11
    "Beautiful mermaid sitting on barnacle-covered rocks at the ocean's edge, " ++
        "long iridescent hair flowing in the sea breeze, moonlight reflection, " ++
        "bioluminescent waves, detailed fantasy illustration",
    // 12
    "Futuristic research laboratory interior, holographic data displays, " ++
        "scientist in white lab coat examining samples, blue neon lighting, " ++
        "clean minimalist design, science fiction concept art",
    // 13
    "Traditional Chinese ink painting of towering mountains and misty rivers, " ++
        "bamboo groves, pine trees on rocky cliffs, calligraphic brushwork, " ++
        "Song Dynasty style, minimalist",
    // 14
    "Fierce grey wolf howling at the full moon on a snowy mountain peak, " ++
        "dramatic cold blue lighting, breath visible in freezing air, " ++
        "wildlife photography style, powerful",
    // 15
    "Colorful coral reef underwater scene, tropical fish in vivid blues and yellows, " ++
        "sea turtle gliding past, shafts of sunlight piercing the water surface, " ++
        "ocean photography, serene",
    // 16
    "Steampunk airship fleet sailing through storm clouds above a Victorian city, " ++
        "brass propellers, gasbags with copper fittings, lightning in the distance, " ++
        "detailed concept art",
    // 17
    "Fierce lioness walking through golden savanna grass at dusk, " ++
        "intense amber eyes, powerful muscular form, " ++
        "National Geographic style wildlife photography, backlit",
    // 18
    "Abandoned overgrown greenhouse interior, broken glass ceiling, " ++
        "wild vines and flowers reclaiming the iron structure, " ++
        "soft diffused light, decay and beauty, artistic photography",
    // 19
    "Young knight in shining plate armor standing before a burning castle, " ++
        "sword raised, determined expression, cape billowing in the wind, " ++
        "heroic fantasy illustration, dramatic lighting",
    // --- harder distractors below ---
    // 20: fire+wings but NOT a dragon
    "A radiant phoenix rising from smoldering ash, crimson and gold plumage, " ++
        "wings wreathed in living flame, mythical rebirth, dramatic dark sky, " ++
        "digital painting, epic fantasy",
    // 21: medieval warrior but grimdark, NOT heroic knight
    "Dark armored knight on a black destrier charging through a thunderstorm, " ++
        "lance lowered, heraldic banner streaming, ominous silhouette, " ++
        "grimdark fantasy, oil painting",
    // 22: Victorian + scientific but NOT steampunk
    "Victorian alchemist laboratory, glass alembics and distillation flasks, " ++
        "esoteric charts pinned to the walls, leather-bound grimoires, " ++
        "candlelit, sepia tones, historical fantasy",
    // 23: Japanese garden but NOT zen
    "Traditional koi pond in a moss-covered stone courtyard, " ++
        "autumn maple reflections on still water, stone lanterns, " ++
        "morning mist, tranquil Japanese scene, photography",
    // 24: big cat wildlife but NOT lioness or tabby
    "Snow leopard crouched on a rocky Himalayan ridge, " ++
        "sharp pale amber eyes, thick spotted fur, breath misting in cold air, " ++
        "mountain peaks behind, wildlife photography",
    // 25: ruins + vegetation but NOT a castle or greenhouse
    "Crumbling jungle temple ruins, massive stone idols draped in creeping vines, " ++
        "shafts of golden light through the forest canopy, ancient mystery, " ++
        "adventure concept art",
    // 26: ocean creature + bioluminescent but NOT a mermaid
    "Eldritch tentacled horror emerging from dark churning ocean depths, " ++
        "bioluminescent appendages, crushing a lighthouse, " ++
        "Lovecraftian cosmic dread, stormy sky, dramatic illustration",
    // 27: abandoned interior but NOT greenhouse
    "Abandoned industrial warehouse interior, shafts of light through broken skylights, " ++
        "rusted machinery and collapsed shelving, pigeons in the rafters, " ++
        "urban decay, moody long-exposure photography",
    // 28: large marine animal, ocean, NOT coral reef or mermaid
    "Massive humpback whale breaching at golden hour, " ++
        "ocean spray catching the warm light, remote open sea, " ++
        "epic scale, wildlife photography",
    // 29: arcane + books but NOT a wizard portrait
    "Magical library interior, towering spiral bookshelves reaching the vaulted ceiling, " ++
        "floating illuminated manuscripts, arcane dust motes in warm amber candlelight, " ++
        "fantasy concept art",
};

// Queries go from easy (exact vocabulary) to hard (requires inference,
// cultural knowledge, or disambiguation between similar prompts).
pub const QUERIES = [_]Query{
    // easy: exact vocab present in the prompt
    .{ .text = "dragon",                          .relevant = &.{0} },
    .{ .text = "mermaid",                         .relevant = &.{11} },
    // medium: vocabulary mismatch, single clear answer
    .{ .text = "fire-breathing reptile",           .relevant = &.{0} },
    .{ .text = "lunar canine",                     .relevant = &.{14} },
    .{ .text = "holographic interface",            .relevant = &.{12} },
    .{ .text = "interstellar combat",              .relevant = &.{5} },
    .{ .text = "ink wash brushwork",               .relevant = &.{13} },
    // medium-hard: two valid answers
    .{ .text = "Victorian clockwork",              .relevant = &.{9, 16} },
    // hard: three valid answers (all Felidae)
    .{ .text = "feline",                           .relevant = &.{4, 17, 24} },
    // hard: two valid (both bioluminescent ocean creatures)
    .{ .text = "bioluminescent ocean creature",    .relevant = &.{11, 26} },
    // hard: two valid (vegetation reclaiming ruins)
    .{ .text = "nature reclaims ruin",             .relevant = &.{18, 25} },
    // hard: requires inference (wizard = spellcasting scholar)
    .{ .text = "spellcasting scholar",             .relevant = &.{7} },
    // hard: taxonomic vocabulary
    .{ .text = "African ungulate",                 .relevant = &.{8} },
    // hard: genre knowledge required
    .{ .text = "Cthulhu mythos",                   .relevant = &.{26} },
    // hard: mythological knowledge
    .{ .text = "mythical firebird",                .relevant = &.{20} },
    .{ .text = "mounted grimdark cavalry",         .relevant = &.{21} },
    .{ .text = "alchemical distillation",          .relevant = &.{22} },
    // hard: taxonomic synonym
    .{ .text = "cetacean breach",                  .relevant = &.{28} },
    .{ .text = "high altitude spotted felid",      .relevant = &.{24} },
    // hard: Japanese cultural concept; two valid (zen garden + koi pond)
    .{ .text = "wabi-sabi",                        .relevant = &.{3, 23} },
};
