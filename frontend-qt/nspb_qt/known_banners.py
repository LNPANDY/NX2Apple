"""Shared known-game banner index and on-demand single-banner cache helper for the Qt front end.

Mirrors `frontend/Sources/NXCore/KnownGameBanners.swift` and `BannerCache.swift` so known Switch and
Switch 2 titles can download a single ~35-200 KB banner immediately without fetching the 90 MB
regional title database first.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Callable

ALLOWED_IMAGE_HOSTS: frozenset[str] = frozenset({
    'img-eshop.cdn.nintendo.net',
    'cdn2.steamgriddb.com',
    'www.nintendo.com',
    'api.nlib.cc',
})

BANNER_EXTS: tuple[str, ...] = ('jpg', 'png', 'jpeg', 'heic', 'webp')
MAX_BANNER_BYTES = 20 << 20
_TITLE_ID_RE = re.compile(r'^[0-9A-F]{16}$')
_NINTENDO_SIZE_RE = re.compile(r'_image\d+w\.')

SWITCH2_FALLBACK_BANNERS: dict[str, str] = {
    '0400245021D2C000': 'https://cdn2.steamgriddb.com/grid/4019460f699df3ca57bb36a6cc8b1ce5.png',  # Yoshi and the Mysterious Book
    '0400380020056000': 'https://cdn2.steamgriddb.com/grid/220a08c045f283231e519ed83cd21466.png',  # Splatoon Raiders
    '04003F40232DE000': 'https://cdn2.steamgriddb.com/grid/30430599d3640690ebddef63609c5f31.png',  # Hyrule Warriors: Age of Imprisonment
    '0400486024DEC000': 'https://cdn2.steamgriddb.com/grid/925526bdfb5910517494acb4db2537d5.png',  # The Legend of Zelda: Ocarina of Time
    '04007EF01F8AE000': 'https://cdn2.steamgriddb.com/grid/f73cc1e0813d90b30a22ca9af2e9c8b0.png',  # Fire Emblem: Fortune's Weave
    '0400A3A01EE4C000': 'https://cdn2.steamgriddb.com/grid/00b97e285bef52b2826cfbeecd4d30f7.png',  # Pokémon Pokopia
    '0400D4201C6EA000': 'https://cdn2.steamgriddb.com/grid/eb3353d1afeb0b6b1c6507bb5d39c757.png',  # Mario Tennis Fever
    '0400E88025B1A000': 'https://cdn2.steamgriddb.com/grid/a82908cc940793dc1d63acfc0218b2f9.jpg',  # Star Fox
}

KNOWN_BANNERS: dict[str, str] = {
    '0100000000010000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_SuperMarioOdyssey_image500w.jpg',
    '0100000011D90000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_PokemonBrilliantDiamond_enGB_image500w.jpg',
    '010005501E68C000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_AceAttorneyInvestigationsCollection_image500w.jpg',
    '010012101468C000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_MetroidPrimeRemastered_image500w.jpg',
    '010013C00E930000': 'https://img-eshop.cdn.nintendo.net/i/60eebc8f7133f685eddbffbe43c8da617ba0a5d699f2008f9c31c6119d1792af.jpg',
    '010014C011146000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_SubnauticaBelowZero_image500w.jpg',
    '010014E00DB56000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_DigimonStoryCyberSleuthCompleteEdition_image500w.jpg',
    '010015100B514000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_SuperMarioBrosWonder_image500w.jpg',
    '0100152000022000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_MarioKart8Deluxe_image500w.jpg',
    '010016100A186000': 'https://img-eshop.cdn.nintendo.net/i/e0fa61fc34b2b044ffda1daa62d3c5a5e7548d99622307eff5abedd7b875e747.jpg',
    '0100199023B2E000': 'https://img-eshop.cdn.nintendo.net/i/c7dcfae0398febc8586cc0fa1d6c0cb3485fdd460fa845f30c11058c65d4b577.jpg',
    '01001F5010DFA000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_PokemonLegendsArceus_EN_image500w.jpg',
    '010020400E1C2000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_RagingLoop_image500w.jpg',
    '010020D01AD24000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_AnimalWell_V3_image500w.jpg',
    '0100217023F6C000': 'https://img-eshop.cdn.nintendo.net/i/80dcfc0b6cbd2c8949a35b8450210d35d3b027ccf935239af68fdd5b44264718.jpg',
    '0100276009872000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_OkamiHD_image500w.jpg',
    '010028600EBDA000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_SuperMario3DWorldAndBowsersFury_image500w.jpg',
    '010029B0118E8000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_NeedForSpeedHotPursuitRemastered_image500w.jpg',
    '010029B018432000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_GhostTrickPhantomDetective_image500w.jpg',
    '01002B00111A2000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_HyruleWarriorsAgeOfCalamity_enGB_image500w.jpg',
    '01002B30028F6000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_Celeste_image500w.jpg',
    '01002CD00A51C000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_BabaIsYou_image500w.jpg',
    '01002DA013484000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_TheLegendOfZeldaSkywardSwordHD_image500w.jpg',
    '01002E7016C46000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_CultOfTheLamb_image500w.jpg',
    '0100300012F2A000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_AdvanceWarsRebootCamp_image500w.jpg',
    '0100317013770000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_MarioAndRabbidsSparksOfHope_enGB_image500w.jpg',
    '010031F019294000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_SuperMonkeyBallBananaRumble_Logo_image500w.png',
    '010032E00E6E2000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_ReturnOfTheObraDinn_image500w.jpg',
    '0100346017304000': 'https://img-eshop.cdn.nintendo.net/i/48b2140ee6181ee47be31e546f5a9bd976bc3b1305f53f9b4d8ad4ee05e47516.jpg',
    '010035F022078000': 'https://www.nintendo.com/eu/media/images/assets/nintendo_switch_games/dragonballsparkingzero/2x1_DragonBallSparkingZero_image500w.jpg',
    '010036E00FB20000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_TheGreatAceAttorneyChronicles_image500w.jpg',
    '010038600B27E000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_Bastion_image500w.jpg',
    '010038B015560000': 'https://www.nintendo.com/eu/media/images/assets/nintendo_switch_games/finalfantasytacticstheivalicechronicles/2x1_FinalFantasyTacticsTheIvaliceChronicles_image500w.jpg',
    '01003E601E324000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_DragonQuestIIIHD2DRemake_image500w.jpg',
    '01003FC01670C000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_13SentinelsAegisRim_image500w.jpg',
    '010040801A4C8000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_Blasphemous2_image500w.jpg',
    '010042000A986000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_DragonQuestBuilders2_image500w.jpg',
    '0100429011144000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_Subnautica_image500w.jpg',
    '010045C014650000': 'https://img-eshop.cdn.nintendo.net/i/455466d36266b78af2a0e09332210717f2df0c54967cc10e0fcb94b7a076e98a.jpg',
    '010049900F546000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_SuperMario3DAllstars_image500w.jpg',
    '010049900F546001': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_SuperMario3DAllstars_image500w.jpg',
    '010049900F546002': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_SuperMario3DAllstars_image500w.jpg',
    '01004A4010FEA000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_Bayonetta3_image500w.jpg',
    '01004AB00A260000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_DarkSoulsRemastered_image500w.jpg',
    '01004D300C5AE000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_KirbyAndTheForgottenLand_onlylogo_enGB_image500w.jpg',
    '010051701FB46000': 'https://www.nintendo.com/eu/media/images/assets/nintendo_switch_games/monstertrain2/2x1_MonsterTrain2_image500w.jpg',
    '01005270232F2000': 'https://img-eshop.cdn.nintendo.net/i/456a25e08dc3e0d2209cd1261a804e08d4eb939649df234da36752d874e9a7cb.jpg',
    '0100535012974000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_Hades_image500w.png',
    '010054B01AD92000': 'https://img-eshop.cdn.nintendo.net/i/3e4a3aa351350e21e7fbb1c65698aab0cd4b37c6d62fc838952c62cfb8f6ae03.jpg',
    '010055D009F78000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_FireEmblemThreeHouses_image500w.jpg',
    '010056B015FE8000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_NierAutomataTheEndOfYorhaEdition_image500w.jpg',
    '010057D006492000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_OctopathTraveler_image500w.jpg',
    '01005CA01580E000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_Persona5Royal_image500w.jpg',
    '01006000040C2000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_YoshisCraftedWorld_image500w.jpg',
    '0100606026F12000': 'https://img-eshop.cdn.nintendo.net/i/f32f745bc141f4b1f238254f9710c4269b26e315307b3263e558b20ef2c331ac.jpg',
    '010061D00DB74000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_OriAndTheBlindForestDefinitiveEdition_image500w.jpg',
    '0100620012D6E000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_BigBrainAcademyBrainVsBrain_enGB_image500w.jpg',
    '010062B01525C000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_Persona4Golden_image500w.jpg',
    '0100633007D48000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/wiiu_download_software_5/H2x1_WiiUDS_HollowKnight_image500w.jpg',
    '010063301BD50000': 'https://www.nintendo.com/eu/media/images/assets/nintendo_switch_games/superrobotwarsy/2x1_SuperRobotWarsY_image500w.jpg',
    '0100646009FBE000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_DeadCells_image500w.jpg',
    '010067300059A000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_MarioAndRabbidsKingdomBattle_EU_image500w.jpg',
    '010069401ADB8000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_UnicornOverlord_image500w.jpg',
    '0100698009C6E000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_Blasphemous_image500w.jpg',
    '010069C01AB82000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_ShinMegamiTenseiVVengeance_image500w.jpg',
    '01006A800016E000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_SuperSmashBrosUltimate_02_image500w.jpg',
    '01006BB00C6F0000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_TheLegendOfZeldaLinksAwakening_image500w.jpg',
    '01006C300E9F0000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_DragonQuestXI_enGB_image500w.jpg',
    '01006D0017F7A000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_MarioLuigiBrothership_GB_en_image500w.jpg',
    '01006F8002326000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_AnimalCrossingNewHorizons_image500w.jpg',
    '01006FE013472000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_MarioPartySuperStars_image500w.jpg',
    '0100713016CCC000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_AITheSomniumFilesnirvanaInitiative_image500w.jpg',
    '01007300020FA000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_AstralChain_image500w.jpg',
    '010074F013262000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_XenobladeChronicles3_image500w.jpg',
    '010076F0049A2000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_Bayonetta1_image500w.jpg',
    '01007820196A6000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_RedDeadRedemption_image500w.jpg',
    '01007960049A0000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_Bayonetta2_image500w.jpg',
    '01007A3009184000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_PrincessPeachShowtime_image500w.jpg',
    '01007BB017812000': 'https://img-eshop.cdn.nintendo.net/i/122954ab00a225034fa09c8e5ba29b2f9fc0b371a8d550c34ebeecc2727522c3.jpg',
    '01007E3006DDA000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_KirbyStarAllies_image500w.jpg',
    '01007EF00011E000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/wiiu_14/SI_WiiU_TheLegendOfZeldaBreathOfTheWild_image500w.jpg',
    '010086A022444000': 'https://img-eshop.cdn.nintendo.net/i/7ca9922741867dc8d55fcf9aabb0c84d4178096a77512a1beadb736288ac98f3.jpg',
    '010089B00D09C000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_AiTheSomniumFiles_image500w.jpg',
    '010089C01E9CA000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_SteamWorldHeist2_image500w.jpg',
    '01008BC024FDE000': 'https://img-eshop.cdn.nintendo.net/i/113f98d19861d9e71000f64e6069e783f177253fdb3e66853fc4ed4d2ffba462.jpg',
    '01008C0016544000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_SeaOfStars_image500w.jpg',
    '01008CF01BAAC000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_TheLegendofZeldaEchoesOfWisdom_image500w.jpg',
    '01008D7016438000': 'https://img-eshop.cdn.nintendo.net/i/0c3e270693e56f6765476b38b140b44178bf9ee06c8a0901bc46d127c1dd3cde.jpg',
    '01008D9022462000': 'https://img-eshop.cdn.nintendo.net/i/8eded68993c30ede0035f814268632f0ff87a7c16fff4af40eec781cb807afa7.jpg',
    '01008DB008C2C000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_PokemonShield_enGB_image500w.jpg',
    '01008F6008C5E000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_PokemonScarletViolet_Violet_enGB_image500w.jpg',
    '01008F701C074000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_SonicSuperstars_image500w.jpg',
    '010092B0091D0000': 'https://img-eshop.cdn.nintendo.net/i/fd89756d29d1f62bcda1f096e48070f1a19e3f503c0aeb86efc2323786cbcc63.jpg',
    '01009320084A4000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_SteamWorldDig_image500w.jpg',
    '010093801237C000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_MetroidDread_image500w.jpg',
    '0100965017338000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_SuperMarioPartyJamboree_image500w.jpg',
    '010097F018538000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_DaveTheDiver_image500w.jpg',
    '010099C022B96000': 'https://img-eshop.cdn.nintendo.net/i/e90d82826b3e3006cf55d534be5e96e0a53999e1d7f761ba90de40ec0055772a.jpg',
    '01009BF0072D4000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_CaptainToadTreasureTracker_image500w.png',
    '01009D901BC56000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_DonkeyKongCountryReturnsHD_image500w.jpg',
    '0100A00019DE0000': 'https://img-eshop.cdn.nintendo.net/i/448cc7528c18f75cf3c49b63b0fbf9e05e0e0827735c22d60407fe5e6f64d451.jpg',
    '0100A3501946E000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_OctopathTravelerII_image500w.jpg',
    '0100A3900C3E2000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_PaperMarioTheOrigamiKing_image500w.jpg',
    '0100A3D008C5C000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_PokemonScarletViolet_Scarlet_enGB_image500w.jpg',
    '0100A5C00D162000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_Cuphead_image500w.jpg',
    '0100A6301214E000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_FireEmblemEngage_EU_image500w.jpg',
    '0100A83022A22000': 'https://img-eshop.cdn.nintendo.net/i/8757425a4deb56a81c1041075789c23b5ebbe89ae30e9dbf5e3025011d74e70a.jpg',
    '0100A9D01C446000': 'https://img-eshop.cdn.nintendo.net/i/78759e8c3ad458d67d31fae6519a364ef6eb6eda9d9dcebb19b72e7aa48290e0.jpg',
    '0100ABD01785C000': 'https://img-eshop.cdn.nintendo.net/i/75484f73fedd25cb830c5d93fbb3fca643a5ec0b09df2815291ead880bc7d6b1.jpg',
    '0100ABF008968000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_PokemonSword_enGB_image500w.jpg',
    '0100ACD0163D0000': 'https://www.nintendo.com/eu/media/images/assets/nintendo_switch_games/batmanarkhamknight/2x1_BatmanArkhamKnight_image500w.jpg',
    '0100AE00096EA000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_HyruleWarriorsDefinitiveEdition_image500w.jpg',
    '0100B04011742000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_MonsterHunterRise_image500w.jpg',
    '0100B7C00933A000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_Pikmin4_image500w.jpg',
    '0100B8A026F14000': 'https://img-eshop.cdn.nintendo.net/i/f32f745bc141f4b1f238254f9710c4269b26e315307b3263e558b20ef2c331ac.jpg',
    '0100B8E016F76000': 'https://img-eshop.cdn.nintendo.net/i/40753a69061ff430337c62d37c3882629ed974f24bf89583098c618c4b609d3b.jpg',
    '0100B99019412000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_MarioVsDonkeyKong_image500w.jpg',
    '0100BA4026E94000': 'https://img-eshop.cdn.nintendo.net/i/62bf3d093962e1b50ebd7a3e6a8d438a58dc9e5a48a2d0549a43c4db0fd3166e.jpg',
    '0100BC0018138000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_SuperMarioRPG_image500w.jpg',
    '0100BC300CB48000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_FinalFantasyXX2HDRemaster_image500w.jpg',
    '0100BF00112C0000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_CatherineFullBody_image500w.jpg',
    '0100C1F0051B6000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_DonkeyKongCountryTropicalFreeze_image500w.jpg',
    '0100C2A01A730000': 'https://www.nintendo.com/eu/media/images/assets/nintendo_switch_games/romanceofthethreekingdoms8remake/2x1_RomanceOfTheThreeKingdoms8Remake_image500w.jpg',
    '0100C49025D3E000': 'https://img-eshop.cdn.nintendo.net/i/e08884815dafeff3f8688181eb8766aa78333ae8fd49d7bcdb01a950e3087c1f.jpg',
    '0100CA9002322000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_SteamWorldDig2_image500w.jpg',
    '0100CC80140F8000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_TriangleStrategy_image500w.jpg',
    '0100CD801CE5E000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_Balatro_image500w.jpg',
    '0100CE4010AAC000': 'https://img-eshop.cdn.nintendo.net/i/a138045cd1ef99d67758093e43de4a697591ef26a898e564d4dc2df08a8260b2.jpg',
    '0100D7C01F254000': 'https://img-eshop.cdn.nintendo.net/i/82b3fe12937d1a8484df338334f28870928b45bbebcdaf06c38117f94207900c.jpg',
    '0100D9F01D474000': 'https://img-eshop.cdn.nintendo.net/i/25965d7880177867c41437e89361dfa87ac440a12fc5560064bad354692ba885.jpg',
    '0100DA801624E000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_Tunic_image500w.jpg',
    '0100DCA0064A6000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_LuigisMansion3_image500w.jpg',
    '0100E44016C22000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_PatricksParabox_image500w.jpg',
    '0100E65002BB8000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_StardewValley_enGB_image500w.jpg',
    '0100E95004038000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_XenobladeChronicles2_image500w.jpg',
    '0100EC9010258000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_StreetsOfRage4_image500w.jpg',
    '0100ECD018EBE000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_PaperMarioTheThousandYearDoor_GB_en_image500w.jpg',
    '0100ED7012DB2000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/H2x1_NSwitchDS_RomanceOfTheThreeKingdomsXIVDiplomacyAndStrategyExpansionPackBundle_image500w.jpg',
    '0100F2C0115B6000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/2x1_NSwitch_TloZTearsOfTheKingdom_Gamepage_image500w.jpg',
    '0100F43008C44000': 'https://www.nintendo.com/eu/media/images/assets/nintendo_switch_games/pokemonlegendsza/2x1_NSwitch2_PokemonLegendsZA_KV_GB_en_image500w.jpg',
    '0100F5D01DA3A000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_download_software_1/2x1_NSwitchDS_BrainMemoryTrainingAcademy_image500w.jpg',
    '0100FD8022DAA000': 'https://img-eshop.cdn.nintendo.net/i/8bbdbdd29d7f552054aa65c07fcd3a9b3c3dafdb590ccbec28e97a582c69d4ad.jpg',
    '0100FF500E34A000': 'https://www.nintendo.com/eu/media/images/10_share_images/games_15/nintendo_switch_4/H2x1_NSwitch_XenobladeChroniclesDefinitiveEdition_image500w.jpg',
    '0400245021D2C000': 'https://cdn2.steamgriddb.com/grid/4019460f699df3ca57bb36a6cc8b1ce5.png',
    '0400380020056000': 'https://cdn2.steamgriddb.com/grid/220a08c045f283231e519ed83cd21466.png',
    '04003F40232DE000': 'https://cdn2.steamgriddb.com/grid/30430599d3640690ebddef63609c5f31.png',
    '0400486024DEC000': 'https://cdn2.steamgriddb.com/grid/925526bdfb5910517494acb4db2537d5.png',
    '040074A01BF12000': 'https://img-eshop.cdn.nintendo.net/i/3a40edb8fc1354911e0907f1494b5678c2fa37acb8925967e638bd63d06e4580.jpg',
    '04007EF01F8AE000': 'https://cdn2.steamgriddb.com/grid/f73cc1e0813d90b30a22ca9af2e9c8b0.png',
    '0400A3A01EE4C000': 'https://cdn2.steamgriddb.com/grid/00b97e285bef52b2826cfbeecd4d30f7.png',
    '0400C3F00006E000': 'https://www.nintendo.com/eu/media/images/assets/nintendo_switch_2_games/mariokartworld/2x1_NSwitch2_MarioKartWorld_image500w.jpg',
    '0400D4201C6EA000': 'https://cdn2.steamgriddb.com/grid/eb3353d1afeb0b6b1c6507bb5d39c757.png',
    '0400E88025B1A000': 'https://cdn2.steamgriddb.com/grid/a82908cc940793dc1d63acfc0218b2f9.jpg',
}


def is_valid_title_id(title_id: str) -> bool:
    return bool(_TITLE_ID_RE.fullmatch((title_id or '').strip().upper()))


def nlib_banner_url(title_id: str) -> str | None:
    """Tier-2 single-title banner endpoint (no 90 MB title database download required)."""
    tid = (title_id or '').strip().upper()
    if not is_valid_title_id(tid):
        return None
    return f'https://api.nlib.cc/nx/{tid}/banner/720p'


def is_allowed_banner_url(url: str, *, allow_file: bool = False) -> bool:
    if not url:
        return False
    parsed = urllib.parse.urlparse(url)
    if allow_file and parsed.scheme == 'file':
        return True
    return parsed.scheme == 'https' and (parsed.hostname or '').lower() in ALLOWED_IMAGE_HOSTS


def is_valid_image_bytes(data: bytes) -> bool:
    """Validate bounded image payload magic bytes (JPEG, PNG, WebP, or HEIF)."""
    if not data or len(data) < 12 or len(data) >= MAX_BANNER_BYTES:
        return False
    if data[:3] == b'\xff\xd8\xff':
        return True
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        return True
    if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        return True
    if data[4:8] == b'ftyp':
        return True
    return False


def image_ext_for_bytes(data: bytes) -> str:
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        return 'png'
    if data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        return 'webp'
    if data[4:8] == b'ftyp':
        return 'heic'
    return 'jpg'


def download_candidates(url: str, *, prefer_large: bool = False) -> list[str]:
    if not url:
        return []
    if prefer_large:
        parsed = urllib.parse.urlparse(url)
        if (parsed.hostname or '').lower() == 'www.nintendo.com' and _NINTENDO_SIZE_RE.search(url):
            large = _NINTENDO_SIZE_RE.sub('_image1600w.', url, count=1)
            if large != url:
                return [large, url]
    return [url]


def read_response_chunked(resp, *, chunk_size: int = 65536, max_bytes: int | None = None) -> bytes:
    """Stream-read an HTTP response in chunks so per-chunk socket timeout replaces a whole-body timeout.

    Falls back to zero-argument `resp.read()` for lightweight test doubles that do not accept a size argument.
    """
    chunks: list[bytes] = []
    total = 0
    while True:
        try:
            part = resp.read(chunk_size)
        except TypeError:
            part = resp.read()
            if max_bytes is not None and len(part) > max_bytes:
                raise ValueError('response exceeds max_bytes')
            return part
        if not part:
            break
        total += len(part)
        if max_bytes is not None and total > max_bytes:
            raise ValueError('response exceeds max_bytes')
        chunks.append(part)
    return b''.join(chunks)


def cached_banner_path(title_id: str, banners_dir: str | os.PathLike | None) -> Path | None:
    if not banners_dir:
        return None
    tid = (title_id or '').strip().upper()
    if not tid:
        return None
    bdir = Path(banners_dir)
    for ext in BANNER_EXTS:
        cand = bdir / f'{tid}.{ext}'
        if cand.is_file():
            return cand
    return None


def local_index_banner_url(title_id: str, banners_dir: str | os.PathLike | None) -> str | None:
    if not banners_dir:
        return None
    tid = (title_id or '').strip().upper()
    if not is_valid_title_id(tid):
        return None
    index_file = Path(banners_dir) / 'banners_index.json'
    if not index_file.is_file():
        return None
    try:
        loaded = json.loads(index_file.read_text(encoding='utf-8'))
        if isinstance(loaded, dict):
            url = str(loaded.get(tid) or '').strip()
            if url:
                return url
    except Exception:
        pass
    return None


def _allow_live_network(opener: Callable | None, allow_network: bool | None) -> bool:
    if opener is not None:
        return True
    if allow_network is not None:
        return allow_network
    if os.environ.get('QT_QPA_PLATFORM') == 'offscreen':
        return False
    # In unittest without a patched urlopen, avoid live internet traffic from unrelated packaging tests.
    if 'unittest' in sys.modules and getattr(urllib.request.urlopen, '__module__', '') == 'urllib.request':
        return False
    return True


def ensure_cached_banner(
    title_id: str,
    banners_dir: str | os.PathLike | None,
    *,
    timeout: float = 15.0,
    opener: Callable | None = None,
    allow_network: bool | None = None,
    prefer_large: bool = False,
) -> str | None:
    """Return a cached banner path for `title_id`, downloading a single banner on demand when absent.

    Looks up local `banners_index.json`, `KNOWN_BANNERS`, and `SWITCH2_FALLBACK_BANNERS` without
    downloading the 90 MB regional title database.
    """
    tid = (title_id or '').strip().upper()
    if not banners_dir or not is_valid_title_id(tid):
        return None
    existing = cached_banner_path(tid, banners_dir)
    if existing is not None:
        return str(existing)
    if not _allow_live_network(opener, allow_network):
        return None

    primary_url = (
        local_index_banner_url(tid, banners_dir)
        or KNOWN_BANNERS.get(tid)
        or SWITCH2_FALLBACK_BANNERS.get(tid)
    )
    candidates: list[tuple[str, float]] = []
    seen_urls: set[str] = set()
    if primary_url:
        for cand in download_candidates(primary_url, prefer_large=prefer_large):
            if cand not in seen_urls:
                seen_urls.add(cand)
                candidates.append((cand, timeout))
    direct_url = nlib_banner_url(tid)
    if direct_url and direct_url not in seen_urls:
        seen_urls.add(direct_url)
        candidates.append((direct_url, min(timeout, 8.0)))

    fetch = opener or urllib.request.urlopen
    bdir = Path(banners_dir)
    for cand, cand_timeout in candidates:
        if not is_allowed_banner_url(cand):
            continue
        try:
            req = urllib.request.Request(cand, headers={'User-Agent': 'NX2Apple/1.5'})
            with fetch(req, timeout=cand_timeout) as resp:
                status = getattr(resp, 'status', 200)
                if status not in (None, 200):
                    continue
                data = read_response_chunked(resp, chunk_size=65536, max_bytes=MAX_BANNER_BYTES)
            if not is_valid_image_bytes(data):
                continue
            bdir.mkdir(parents=True, exist_ok=True)
            ext = image_ext_for_bytes(data)
            dest = bdir / f'{tid}.{ext}'
            tmp = bdir / f'.{tid}.{uuid.uuid4().hex}.{ext}.tmp'
            try:
                tmp.write_bytes(data)
                os.replace(tmp, dest)
            finally:
                if tmp.exists():
                    try:
                        tmp.unlink()
                    except OSError:
                        pass
            return str(dest)
        except Exception:
            continue
    return None
